{-# LANGUAGE OverloadedStrings, DoAndIfThenElse #-}

module Git.Repository (
    checkoutHead
  , readHead
  , resolveTree
) where

import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString as B
import Text.Printf                                          (printf)
import Git.Common                                           (GitRepository(..), ObjectId, WithRepository)
import Git.Store.Blob
import Git.Store.ObjectStore
import Git.Store.Index
import System.FilePath
import System.Directory
import Data.Char                                            (isSpace)
import System.Posix.Files
import Control.Monad.Reader
import Numeric                                              (readOct)

-- | Updates files in the working tree to match the given <tree-ish>
checkoutHead :: WithRepository ()
checkoutHead = do
    repo <- ask
    let dir = getName repo
    tip <- readHead
    maybeTree <- resolveTree tip
    indexEntries <- maybe (return []) (walkTree [] dir) maybeTree
    writeIndex indexEntries

-- TODO Improve error handling: Should return an error instead of
-- of implicitly skipping erroneous elements.
walkTree :: [IndexEntry] -> FilePath -> Tree -> WithRepository [IndexEntry]
walkTree acc parent tree = do
    let entries = getEntries tree
    foldM handleEntry acc entries
    where handleEntry acc' (TreeEntry "40000" path sha') = do
                                let dir = parent </> toFilePath path
                                liftIO $ createDirectory dir
                                maybeTree <- resolveTree $ toHex sha'
                                maybe (return acc') (walkTree acc' dir) maybeTree
          handleEntry acc' (TreeEntry mode path sha') = do
                        repo <- ask
                        let fullPath = parent </> toFilePath path
                        content <- liftIO $ readBlob repo $ toHex sha'
                        maybe (return acc') (\e -> do
                                liftIO $ B.writeFile fullPath (getBlobContent e)
                                let fMode = fst . head . readOct $ C.unpack mode
                                liftIO $ setFileMode fullPath fMode
                                indexEntry <- asIndexEntry fullPath sha'
                                return $ indexEntry : acc') content
          toFilePath = C.unpack
          asIndexEntry path sha' = do
                stat <- liftIO $ getFileStatus path
                indexEntryFor path Regular sha' stat

-- | Resolve a tree given a <tree-ish>
-- Similar to `parse_tree_indirect` defined in tree.c
resolveTree :: ObjectId -> WithRepository (Maybe Tree)
resolveTree sha' = do
        repo <- ask
        blob <- liftIO $ readBlob repo sha' -- readBlob :: GitRepository -> ObjectId -> IO (Maybe Blob)
        maybe (return Nothing) walk blob
    where walk  (Blob _ BTree sha1)                = do
                                                      repo <- ask
                                                      liftIO $ readTree repo sha1
          walk  c@(Blob _ BCommit _)               = do
                                                        let maybeCommit = parseCommit $ getBlobContent c
                                                        maybe (return Nothing) extractTree maybeCommit
          walk _                                   = return Nothing

extractTree :: Commit -> WithRepository (Maybe Tree)
extractTree commit = do
    let sha' = C.unpack $ getTree commit
    repo <- ask
    liftIO $ readTree repo sha'

toHex :: C.ByteString -> String
toHex bytes = C.unpack bytes >>= printf "%02x"

readHead :: WithRepository ObjectId
readHead = do
    repo <- ask
    let gitDir = getGitDirectory repo
    ref <- liftIO $ C.readFile (gitDir </> "HEAD")
    -- TODO check if valid HEAD
    let unwrappedRef = C.unpack $ strip $ head $ tail $ C.split ':' ref
    obj <- liftIO $ C.readFile (gitDir </> unwrappedRef)
    return $ C.unpack $ strip obj
  where strip = C.takeWhile (not . isSpace) . C.dropWhile isSpace


