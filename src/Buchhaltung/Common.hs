{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}

-- convert account transactions in csv format to ledger entries
-- pesco, 2009 http://www.khjk.org/log/2009/oct.html

module Buchhaltung.Common
  (module Buchhaltung.Common
  ,module Buchhaltung.Utils
  ,module Buchhaltung.Types
  )
where

import           Buchhaltung.Types
import           Buchhaltung.Utils
import           Control.Applicative ((<$>))
import           Control.Arrow
import           Control.Lens hiding (noneOf)
import           Control.Monad.RWS.Strict
import           Control.Monad.Reader.Class
import           Control.Monad.Writer
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import           Data.Array
import qualified Data.ByteString as B
import           Data.Char
import qualified Data.Csv as CSV
import           Data.Csv.Parser
import           Data.Decimal
import           Data.Either.Utils
import           Data.Foldable
import qualified Data.HashMap.Strict as HM
import           Data.Hashable
import           Data.List
import qualified Data.List.NonEmpty as E
import           Data.List.Split
import qualified Data.ListLike as L
import qualified Data.ListLike.String as L
import           Data.Maybe
import qualified Data.Monoid as Monoid
import           Data.Monoid hiding (Any)
import           Data.Ord
import           Data.String
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL
import           Data.Text.Lazy.Encoding
import qualified Data.Text.Lazy.Encoding as S
import qualified Data.Text.Lazy.IO as TL
import           Data.Time.Calendar
import           Data.Time.Format
import           Data.Traversable (traverse)
import qualified Data.Vector as V
import           Formatting (format, (%))
import qualified Formatting.ShortFormatters as F
import           Hledger.Data hiding (at)
import           Hledger.Query
import           Hledger.Read
import           Hledger.Reports (defreportopts)
import           Hledger.Reports.EntriesReport (entriesReport)
import           Hledger.Utils.Text
import           System.IO
import           Text.Parsec
import qualified Text.Parsec.Text as T
import qualified Text.PrettyPrint.Boxes as P
import           Text.Printf

-- * CONFIGURATION


-- * CSV PARSER
readcsv :: Char -> T.Text -> [[T.Text]]
readcsv sep = map (readcsvrow sep) . T.lines

readcsvrow :: Char -> T.Text -> [T.Text]
readcsvrow sep s = either (error.msg.show) id (parse (p_csvrow sep) "stdin" s)
  where msg x = printf "CSV (sep %c) Parsing error:\n\n%v\n\n%s" sep s

p_csvrow :: Char -> T.Parser [T.Text]
p_csvrow sep = sepBy1 (p_csvfield sep) (char sep)

p_csvfield :: Char -> T.Parser T.Text
p_csvfield sep = fmap T.pack $ between (char '"') (char '"') p_csvstring
                 <|> many (noneOf [sep])

p_csvstring :: T.Parser String
p_csvstring = many (noneOf "\"" <|> (string escapedDoubleQuotes >> return '"'))

escapedDoubleQuotes = "\\\""

parens :: Parsec T.Text () Int
parens = ( do char ('('::Char)
              m <- parens
              char ')'
              n <- parens
              return $ max (m+1) n
         )  <|> return 0

-- * dbacl output parser

testdbacl = parseTest (
  dbacl_parser [
      "Aktiva:Transfer:Visa"
      ,"Aktiva:Transfer"
      ]
  ) ("Aktiva:Transfer 134.32 Aktiva:Transfer:Visa Aktiva:Transfer:Visa 9129.73 a " :: String)

-- | parse dbacl output (see testdbacl for the format of dbacl's output)
dbacl_parse :: [AccountName]
            -> String
            -> Either ParseError [(AccountName,String)]
dbacl_parse accounts = fmap conv . parse (dbacl_parser sorted) ""
  where conv = map (liftM2 (,) fst (L.unwords . snd))
        sorted = sortBy (flip $ comparing T.length) $ accounts

dbacl_parser :: [AccountName] -> Parsec String () [(AccountName, [String])]
dbacl_parser accounts = weiter []
  where weiter :: [(AccountName, [String])] -> Parsec String () [(AccountName, [String])]
        weiter res = choice ((map (cat res) accounts) ++ [info res] )
        cat res y = do newc <- try $ do string $ T.unpack y
                                        space
                                        return y
                       spaces
                       weiter $ (newc,[]) : res
        info ((c,i):res) = do w <- try $ manyTill anyChar (many1 space)
                              weiter $ (c,i <> [w]) : res
                           <|> do { w <- many anyChar;  return ((c,i++[w]):res) }
        info [] = fail "empty list in dbacl_parser: This was not planned"


-- * Utilities



idx :: (Eq a, Show a) => [a] -> a -> Int
idx xs x = maybe (error (show x++": CSV Field not found")) id (findIndex (==x) xs)

-- * Dates 


-- | Read the journal file again, before applying Changes (to not
-- overwrite possible changes, that were made in the mean time)
-- saveChanges :: String -- ^ journal path
--                -> (Journal-> (Journal, Integer))  
--                -> IO Journal
saveChanges
  :: (MonadReader (Options User config env) m, MonadIO m)
  =>  (Journal -> (Journal, Integer))
  -- ^ modifier, returning number of changed
  -> m Journal
saveChanges change = do
  journalPath <- absolute =<< readLedger imported
  liftIO $ do
    ej <- readJournalFile Nothing Nothing False -- ignore balance assertions
          journalPath
    -- print $ length todos
    -- putStr $ unlines $ show <$> todos
    -- either error (print.length.jtxns) ej
    let (j, n) = either error change ej
    if n == 0 then putStrLn "\nNo transactions were changed!\n"
      else do let res = showTransactions j
              writeFile journalPath res
              putStrLn $ "\n"++ show n ++" Transactions were changed"
    return j

mixed' = mixed . (:[])

showTransactions :: Hledger.Data.Journal -> [Char]
showTransactions = concatMap showTransactionUnelided .
  entriesReport defreportopts Hledger.Query.Any

-- * Lenses
 
jTrans :: Lens' Journal [Transaction]
jTrans = lens jtxns $ \j y->j{jtxns=y}

tPosts :: Lens' Transaction [Posting]
tPosts = lens tpostings $ \t y -> t{tpostings=y}

pAcc :: Lens' Posting AccountName
pAcc = lens paccount $ \p y -> p{paccount=y}

-- | changes a given transaction in a joiurnal an d counts the results
changeTransaction
  :: [Maybe (Transaction, Transaction)]
  -> Journal
  -> (Journal, Integer)
changeTransaction ts = countUpdates (jTrans . traverse) h
  where
    h t1 = asum $ fmap g ts
      where g Nothing = Nothing
            g (Just (t2, tNew)) | t1 == t2 = Just tNew
            g _                 |  True    = Nothing
  
-- | Update a traversal and count the number of updates
countUpdates :: Traversal' s a
             -> (a -> Maybe a)
             -> s -> (s, Integer)
countUpdates trav mod = second getSum . runWriter . trav g
  where g x = maybe (return x) ((tell (Sum 1) >>) . return) $ mod x

-- instance Monoid.Monoid Integer where
--   mempty = 0
--   mappend = (+)

data WithSource a = WithSource { wTx :: Transaction
                               , wIdx :: Int
                               -- ^ index of the posting with source
                               , wPosting :: Posting
                               , wSource :: Source
                               , wInfo :: a
                               }
  deriving (Functor)



-- instance Hashable Day where 
--   hash = fromInteger . toModifiedJulianDay
--   hashWithSalt salt = hashWithSalt salt . toModifiedJulianDay
  
-- instance Hashable Transaction where 
  
-- instance Hashable Posting where 
-- instance Hashable PostingType where 
-- instance Hashable MixedAmount where 
-- instance Hashable Amount where 
  
-- | extracts the source line from a Transaction
extractSource :: ImportTag -> Transaction
              -> Either String (WithSource ())
extractSource tag' tx =
  left (<> "\nComments: "
        <> T.unpack (L.unlines $ pcomment <$> ps))
  $ g $ asum $ zipWith f [0..] ps
  where f i p = fmap ((,,) i p) . E.nonEmpty . tail
              . T.splitOn tag $ pcomment p
        tag = commentPrefix tag'
        g Nothing = Left $ printf "no comment with matching tag '%s' found." tag
        g (Just (i,p,n)) = do
          source <- A.eitherDecode' . S.encodeUtf8
                    . TL.fromStrict . E.head $ n
          return $ WithSource tx i p source ()
        ps = tpostings tx

injectSource ::  ImportTag -> Source -> Transaction -> Transaction
injectSource tag source t = t
  {tpostings = [ p1
               , p2{pcomment =
                    commentPrefix tag <> TL.toStrict (json source)
                   }]}
  where [p1,p2] = tpostings t

-- instance MonadReader (Options user Config env) m => ReaderM user env m

  
commentPrefix :: ImportTag -> T.Text
commentPrefix (ImportTag tag) = tag <> ": "


trimnl = mconcat . T.lines

-- * make CSV data easier to handle

-- http://hackage.haskell.org/package/cassava-0.4.1.0/docs/Data-Csv.html#t:NamedRecord
-- parseCsv :: CSV.FromField a => String -> V.Vector (HM.HashMap B.ByteString a)

type MyRecord = (HM.HashMap T.Text T.Text)

parseCsv :: Char -- ^ separator
         -> TL.Text -> ([T.Text], [MyRecord])
parseCsv sep = either error ((fmap T.decodeUtf8 . V.toList)
                             *** V.toList)
               . CSV.decodeByNameWith CSV.defaultDecodeOptions
               { decDelimiter = fromIntegral $ ord sep }
               . encodeUtf8

getCsvConcat
  :: [T.Text] -> MyRecord -> T.Text
getCsvConcat x record = L.unwords $ flip getCsv record <$> x

getCsv :: T.Text -> MyRecord -> T.Text
getCsv c x = lookupErrD (show (HM.keys x)) HM.lookup c x

-- * Import Types


data ImportedEntry' a s = ImportedEntry {
  ieT :: Transaction -- ^ transaction without postings (they will be inserted later)
  ,iePostings :: a
  ,ieSource :: s -- ^ source to check for duplicates and for Bayesian matching
  } deriving Show

type ImportedEntry =  ImportedEntry' (AccountId, T.Text) Source
  -- ^ postings of [acount,amount]: only ImportedEntry with one
  -- posting is currently implemented in the statists functionality of
  -- Add.hs (See PROBLEM1) as well in the duplicates algorithm in 'addNew'

type FilledEntry =  ImportedEntry' () Source

fromFilled :: FilledEntry -> Entry
fromFilled x = x{ieSource = Right $ ieSource x}
  
type Entry =  ImportedEntry' () (Either String Source)

-- | helper function to create transaction for ImportedEntry
genTrans :: Day -> Maybe Day -> T.Text -> Transaction
genTrans date date2 desc =
  nulltransaction{tdate=date, tdescription=desc, tdate2=date2}

normalizeMixedAmountWith
  :: (Amount -> Decimal) -> MixedAmount -> MixedAmount
normalizeMixedAmountWith f (Mixed ams) = Mixed $ g <$> ams
  where g a =  a{aquantity = normalizeDecimal $ f a}
  
data Importer env = Importer
  { iModifyHandle :: Maybe (Handle -> IO ())
  -- ^ e.g. 'windoof'
  , iImport :: T.Text -> CommonM env [ImportedEntry]
  }

windoof :: Maybe (Handle -> IO ())
windoof = Just $ \h -> hSetEncoding h latin1
                       >> hSetNewlineMode h universalNewlineMode


parseDatum :: T.Text -> Day
parseDatum = parseTimeOrError True defaultTimeLocale "%d.%m.%Y" . T.unpack

-- * Pretty Printing

table :: [Int] -- ^ max width
      -> [T.Text] -- ^ Header
      -> [[T.Text]] -- ^ list of cols
      -> P.Box
table w h = table1 . table2 w h
  
table1 :: [[P.Box]] -- ^ list of rows
       -> P.Box
table1 (header:rows) = P.punctuateH P.top
             (P.vcat P.top $ replicate (ml P.rows cols2) $ P.text " | ")
             cols2
   where h colHead col = P.vcat P.left $ colHead : sep : col
           where sep = text' $ L.replicate (ml P.cols $ colHead : col) '-'
         ml f = maximum . fmap f
         cols2 = zipWith h header $ transpose rows
                                      
table2 :: [Int] -- ^ max width
       -> [T.Text] -- ^ Header
       -> [[T.Text]] -- ^ list of cols
       -> [[P.Box]] -- ^ list of rows
table2 widths header cols =
  toRow <$> (header : transpose cols)
  where 
        toRow = g . zipWith asd widths
        asd w = P.para P.left w . T.unpack
        g row = P.alignVert P.top mr <$> row
          where mr = maximum $ P.rows <$> row

mlen :: L.ListLike l e => [l] -> Int
mlen = maximum . fmap L.length

text' :: T.Text -> P.Box
text' = P.text . T.unpack
