import System.Environment (getArgs)
import System.Process
import System.INotify
import qualified Data.ByteString.Char8 as BS
import Data.ByteString (ByteString)
import Control.Monad (void, when)
import System.Console.GetOpt
import System.FilePath
import System.IO
import System.Posix.Files (readSymbolicLink)

data TextColor = NoColor | Green | Red

data Options = Options
  { mainFile :: String
  , pdfFile :: String
  , bibtexFile :: Maybe String
  , auxFiles :: [String]
  }

options :: [OptDescr (Options -> Options)]
options =
  [ Option ['b'] ["bibtex"] (ReqArg (\b o -> o { bibtexFile = Just b }) "FILE") "the bibtex file your tex file uses"
  ]

header :: String
header = "Usage: make-latex texFile [OPTION...] files..."

parseOptions :: [String] -> IO Options
parseOptions [] = ioError (userError (usageInfo header options))
parseOptions (file:args) = case getOpt Permute options args of
  (o,n,[]) -> return $ foldl (flip id) (Options file (replaceExtension file "pdf") Nothing n) o
  (_,_,errs) -> ioError (userError (concat errs ++ usageInfo header options))

say :: TextColor -> String -> IO ()
say color thing = putStrLn $ escapeStart ++ "make-latex: " ++ thing ++ escapeStop
 where
  escapeStart = case color of
    NoColor -> ""
    Green   -> "\x1b[32m"
    Red     -> "\x1b[31m"
  escapeStop = "\x1b[0m"

-- variant of Process.readProcess that returns the output of the process as [ByteString]
readProcessBS :: FilePath -> [String] -> IO [ByteString]
readProcessBS prog args = do
  (_, Just hout, _, _) <- createProcess (proc prog args) { std_out = CreatePipe }
  fmap (BS.split '\n') $ BS.hGetContents hout


latexWarning, overfullHboxWarning, labelsChangedWarning, latexError, lineNumber :: ByteString
latexWarning = BS.pack "LaTeX Warning:"
latexError = BS.pack "!"
lineNumber = BS.pack "l."
overfullHboxWarning = BS.pack "Overfull \\hbox"
labelsChangedWarning = BS.pack "LaTeX Warning: Label(s) may have changed. Rerun to get cross-references right."

isInteresting :: ByteString -> Bool
isInteresting line =
     latexWarning `BS.isPrefixOf` line
  || overfullHboxWarning `BS.isPrefixOf` line
  || latexError `BS.isPrefixOf` line
  || lineNumber `BS.isPrefixOf` line

onlyInterestingLines :: [ByteString] -> [ByteString]
onlyInterestingLines = filter isInteresting

-- some output of pdflatex contains non-utf8 characters, so we cannot use Strings
make :: String -> Bool -> IO ()
make file isRerun = do
  output <- fmap onlyInterestingLines $ readProcessBS "pdflatex"
    [ "--halt-on-error"
    , "-interaction=nonstopmode"
    , "-synctex=1"
    , file]
  mapM_ BS.putStrLn output
  let color = if null output then Green else Red
  say color "latex run complete -------------------------"
  when (not isRerun && labelsChangedWarning `elem` output) $
   do
    say NoColor "rerunning"
    make file True
    -- pdflatex deletes the result on error which is annoying, but when we want
    -- to use synctex there is nothing we can do.

makeBibtex :: Options -> IO ()
makeBibtex opts = do
  maybe (return ()) (\b -> readProcessBS "bibtex" [b] >>= mapM_ BS.putStrLn) (bibtexFile opts)
  make (mainFile opts) False
  make (mainFile opts) False

doWatch :: Options -> INotify -> Event -> IO ()
doWatch opts inotify _ = do
  make (mainFile opts) False
  -- we use Move because that's what vim does when writing a file
  -- OneShot because after Move the watch becomes invalid.
  void $ addWatch inotify [Move,OneShot] (mainFile opts) (doWatch opts inotify)

commandLoop :: Options -> IO ()
commandLoop opts = do
  c <- getChar
  case c of
    'q' -> return ()
    'm' -> make (mainFile opts) False >> commandLoop opts
    'b' -> makeBibtex opts >> commandLoop opts
    't' -> spawnTerminal (mainFile opts) >> commandLoop opts
    'e' -> spawnTexEditor (mainFile opts) >> commandLoop opts
    'p' -> spawnPdfViewer (pdfFile opts) >> commandLoop opts
    _   -> putStr "unknown command " >> putChar c >> putStrLn "" >> commandLoop opts

spawnPdfViewer :: String -> IO ProcessHandle
spawnPdfViewer file = spawnProcess "zathura" ["-s", "-x", "vim --servername SYNCTEX --remote-send %{line}gg", file]

spawnTexEditor :: String -> IO ProcessHandle
spawnTexEditor file = spawnProcess "urxvt" ["-e", "sh", "-c", "vim --servername SYNCTEX " ++ file]

spawnTerminal :: String -> IO ProcessHandle
spawnTerminal file = do
  dir <- takeDirectory `fmap` readSymbolicLink file
  spawnProcess "urxvt" ["-e", "bash", "-cd", dir]

main :: IO ()
main = do
  args <- getArgs
  opts <- parseOptions args

  inotify <- initINotify
  say NoColor $ "watching " ++ mainFile opts ++ "; output is " ++ pdfFile opts
  doWatch opts inotify Ignored

  hSetBuffering stdin NoBuffering
  hSetEcho stdin False
  commandLoop opts

  say NoColor "bye"
