{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE CPP #-}
module Main (main) where
import Hasktags
import Tags

import System.Environment

import Data.List

import System.IO
import System.Directory
#ifdef VERSION_unix
import System.Posix.Files
#endif
import System.FilePath ((</>))
import System.Console.GetOpt
import System.Exit
import Control.Monad

options :: [OptDescr Mode]
options = [ Option "c" ["ctags"]
            (NoArg CTags) "generate CTAGS file (ctags)"
          , Option "e" ["etags"]
            (NoArg ETags) "generate ETAGS file (etags)"
          , Option "b" ["both"]
            (NoArg BothTags) "generate both CTAGS and ETAGS"
          , Option "a" ["append"]
              (NoArg Append)
            $ "append to existing CTAGS and/or ETAGS file(s). After this file "
              ++ "will no longer be sorted!"
          , Option "" ["ignore-close-implementation"]
              (NoArg IgnoreCloseImpl)
            $ "ignores found implementation if its closer than 7 lines  - so "
              ++ "you can jump to definition in one shot"
          , Option "o" ["output"]
            (ReqArg OutRedir "")
            "output to given file, instead of 'tags', '-' file is stdout"
          , Option "f" ["file"]
            (ReqArg OutRedir "")
            "same as -o, but used as compatibility with ctags"
          , Option "x" ["extendedctag"]
            (NoArg ExtendedCtag) "Generate additional information in ctag file."
          , Option "" ["cache"] (NoArg CacheFiles) "Cache file data."
          , Option "L" ["follow-symlinks"] (NoArg FollowDirectorySymLinks) "follow symlinks when recursing directories"
          , Option "S" ["suffixes"] (OptArg suffStr ".hs,.lhs") "list of hs suffixes including \".\""
          , Option "h" ["help"] (NoArg Help) "This help"
          ]
  where suffStr Nothing = HsSuffixes [ ".hs", ".lhs" ]
        suffStr (Just s) = HsSuffixes $ strToSuffixes s
        strToSuffixes = lines . map commaToEOL
        commaToEOL ',' = '\n'
        commaToEOL x = x


main :: IO ()
main = do
        progName <- getProgName
        args <- getArgs
        let usageString =
                   "Usage: " ++ progName
                ++ " [OPTION...] [files or directories...]\n"
                ++ "directories will be replaced by DIR/**/*.hs DIR/**/*.lhs\n"
                ++ "Thus hasktags . tags all important files in the current\n"
                ++ "directory.\n"
                ++ "\n"
                ++ "If directories are symlinks they will not be followed\n"
                ++ "unless you pass -L.\n"
                ++ "\n"
                ++ "A special file \"STDIN\" will make hasktags read the line separated file\n"
                ++ "list to be tagged from STDIN.\n"
        let (modes, files_or_dirs, errs) = getOpt Permute options args

        let hsSuffixes = head [ s | (HsSuffixes s) <- modes ]

        let followSymLinks = FollowDirectorySymLinks `elem` modes

        filenames
          <- liftM (nub . concat) $ mapM (dirToFiles followSymLinks hsSuffixes) files_or_dirs

        when (errs /= [] || elem Help modes || files_or_dirs == [])
             (do putStr $ unlines errs
                 putStr $ usageInfo usageString options
                 exitWith (ExitFailure 1))

        when (filenames == []) $ putStrLn "warning: no files found!"

        let mode = getMode (filter ( `elem` [BothTags, CTags, ETags] ) modes)
            openFileMode = if Append `elem` modes
                           then AppendMode
                           else WriteMode
        filedata <- mapM (findWithCache (CacheFiles `elem` modes)
                                        (IgnoreCloseImpl `elem` modes))
                         filenames

        when (mode == CTags)
             (do ctagsfile <- getOutFile "tags" openFileMode modes
                 writectagsfile ctagsfile (ExtendedCtag `elem` modes) filedata
                 hClose ctagsfile)

        when (mode == ETags)
             (do etagsfile <- getOutFile "TAGS" openFileMode modes
                 writeetagsfile etagsfile filedata
                 hClose etagsfile)

        -- avoid problem when both is used in combination
        -- with redirection on stdout
        when (mode == BothTags)
             (do etagsfile <- getOutFile "TAGS" openFileMode modes
                 writeetagsfile etagsfile filedata
                 ctagsfile <- getOutFile "tags" openFileMode modes
                 writectagsfile ctagsfile (ExtendedCtag `elem` modes) filedata
                 hClose etagsfile
                 hClose ctagsfile)

-- suffixes: [".hs",".lhs"], use "" to match all files
dirToFiles :: Bool -> [String] -> FilePath -> IO [ FilePath ]
dirToFiles _ _ "STDIN" = fmap lines $ hGetContents stdin
dirToFiles followSyms suffixes p = do
  isD <- doesDirectoryExist p
  isSymLink <-
#ifdef VERSION_unix
    isSymbolicLink `fmap` getSymbolicLinkStatus p
#else
    return False
#endif
  case isD of
    False -> return $ if matchingSuffix then [p] else []
    True ->
      if isSymLink && not followSyms
        then return []
        else do
          -- filter . .. and hidden files .*
          contents <- filter ((/=) '.' . head) `fmap` getDirectoryContents p
          concat `fmap` (mapM (dirToFiles followSyms suffixes . (</>) p) contents)
  where matchingSuffix = any (`isSuffixOf` p) suffixes
