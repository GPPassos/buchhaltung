{-# LANGUAGE FlexibleContexts #-}
module Buchhaltung.Commandline where

import           Buchhaltung.AQBanking
import           Buchhaltung.Add
import           Buchhaltung.Common
import           Buchhaltung.Importers
import           Buchhaltung.Match
import           Control.Arrow
import           Control.DeepSeq
import           Control.Exception
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.RWS.Strict
import           Control.Monad.Reader
import           Data.Maybe
import           Data.Monoid
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Hledger.Data (Journal)
import           Hledger.Read (readJournalFiles, ensureJournalFileExists)
import           Hledger.Utils (readFileOrStdinAnyLineEnding)
import           Options.Applicative
import           System.Directory
import           System.Environment
import           System.Exit
import           System.FilePath
import           System.IO
import qualified Text.PrettyPrint.ANSI.Leijen as D
import           Text.Printf

-- * Option parsers
  
mainParser = do
  env <- getEnvironment
  home <- try getHomeDirectory :: IO (Either SomeException FilePath)
  return $ info
    ( helper *> (Options
                <$> subparser commands
                <*> userP
                <*> profile env home
                <*> pure ()
                <*> pure ()
              )
    ) mempty

paragraph = foldr ((D.</>) . D.text) mempty . words

userP :: Parser (Maybe Username)
userP = optional $ fmap (Username . T.pack) $ argument str $
        metavar "USER"
        <> helpDoc
        (Just $ paragraph "Select the user. Default: first configured user")

envVar = "BUCHHALTUNG"

-- | optparse profile folder
profile
  :: Exception b =>
     [(String, FilePath)] -> Either b FilePath -> Parser String
profile env home = strOption $
  long "profile"
  <> value (fromMaybe (either throw buch home) envBuch)
  <> short 'p'
  <> metavar "FOLDER"
  <>  helpDoc (Just $
       paragraph "path to the profile folder. Precedence (highest to lowerst):"
        D.<$> D.text "1. this command line option"
        D.<$> paragraph (printf "2. Environment option: \"%s\" %s" envVar $
                         (maybe "(not set)" (printf "= '%s'") envBuch :: String ))
        D.<$> paragraph (printf "3. %s %s" (buch "~") $
                          either (const "(home dir not available)")
                          (("= " ++) . buch) home)
              )
  where buch = (</> ".buchhaltung")
        envBuch = lookup envVar env
  
-- | optparse command parser  
-- commands :: Parser Action
commands :: Mod CommandFields Action
commands =
  command' "add"
  (Add . fmap (Username . T.pack) <$> many
    (strOption (short 'w' <> help "with partner USERNAME"
                 <> metavar "USERNAME")))
  (progDesc "manual entry of new transactions")
  
  <> command' "import"
  (Import <$> strArgument (metavar "FILENAME")
    <*> subparser importOpts)
  (progDesc "import transactions from FILENAME")
  
  <> command' "aqbanking"
  (AQBanking <$>
    (switch $ short 'm' <> help "run match after import")
    <*> (fmap not $ switch $ short 'n' <> help "do not fetch new transactions"))
  (progDesc
   "fetch and import AQ Banking transactions (using \"aqbanking request\" and \"listtrans\")")
  
  <> command' "match" (pure Match)
  (progDesc "manual entry of new transactions")
  
  <> command' "setup" (pure Setup)
  (progDesc "initial setup of AQBanking")
  
command' str parser infomod =
  command str $ info (helper *> parser) infomod

importOpts :: Mod CommandFields ImportAction
importOpts = 
  command' "paypal"
  (Paypal . T.pack <$> strArgument
    (help "paypal username (as configured in 'bankAccounts')"
      <> metavar "PAYPAL_USERNAME"))
  (progDesc "import from german Paypal CSV export with \"alle guthaben relevanten Zahlungen (kommagetrennt) ohne warenkorbdetails\"")

  <> command' "aqbanking"
  (pure AQBankingImport)
  (progDesc "import CSV generated by \"aqbankingcli listtrans\"")

-- * Running Option Parsers and Actions

run :: Action -> FullOptions () -> ErrorT IO ()
run (Add partner) options =
  void $ withJournals [imported, addedByThisUser] options
  $ runRWST add options{oEnv = partner}

run (Import file action) options = runImport action
  where runImport (Paypal puser) =
          importReadWrite paypalImporter options{oEnv = puser} file
        runImport AQBankingImport =
          importReadWrite aqbankingImporter options file

run (AQBanking doMatch doRequest) options = do
  res <- runAQ options $ aqbankingListtrans doRequest
  void $ runRWST
    (mapM (importWrite $ iImport aqbankingImporter) res)
    options ()
  when doMatch $ run Match options

run Setup options = void $ runAQ options aqbankingSetup
  
run Match options =
  withSystemTempDirectory "dbacl" $ \tmpdir -> do
  withJournals [imported] options $ match options{oEnv = tmpdir}
  
-- | performs an action taking a journal as argument. this journal is
-- read from 'imported' and 'addedByThisUser' ledger files
-- withJournals ::
--   [Ledgers -> FilePath]
--   ->  FullOptions () 
--   -> (Journal -> ErrorT IO b) -> ErrorT IO b
withJournals
  :: (MonadError Msg m, MonadIO m) =>
     [Ledgers -> FilePath]
     -> Options User config env -> (Journal -> m b) -> m b
withJournals journals options f = do
  liftIO $ printf "(Reading journal from '%s')\n...\n\n" $ show jfiles
  journal <- liftIO $
    readJournalFiles Nothing Nothing False jfiles
  either (throwError . T.pack) f journal
  where jfiles = runReader (mapM (absolute <=< readLedger)
                           journals) options

runMain :: IO ()
runMain = do
  opts <- evaluate . force =<<
    customExecParser (prefs $ showHelpOnError <> showHelpOnEmpty)
    =<< mainParser
    :: IO (RawOptions ())
  let
    prog ::  ErrorT IO ()
    prog = do
        config <- liftIO $ readConfigFromFile $ oProfile opts
        run (oAction opts) =<< toFull opts config
  either (error . T.unpack) return =<< runExceptT prog
