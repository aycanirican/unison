{-# Language BangPatterns #-}
{-# Language FunctionalDependencies #-}
{-# Language GeneralizedNewtypeDeriving #-}

module EasyTest where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Reader
import Data.List
import Data.Map (Map)
import Data.Word
import GHC.Stack
import System.Exit
import System.Random (Random)
import qualified Control.Concurrent.Async as A
import qualified Data.Map as Map
import qualified System.Random as Random

data Status = Failed | Passed !Int | Skipped

combineStatus :: Status -> Status -> Status
combineStatus Skipped s = s
combineStatus s Skipped = s
combineStatus Failed _ = Failed
combineStatus _ Failed = Failed
combineStatus (Passed n) (Passed m) = Passed (n + m)

data Env =
  Env { rng :: TVar Random.StdGen
      , messages :: String
      , results :: TBQueue (Maybe (TMVar (String, Status)))
      , note_ :: String -> IO ()
      , allow :: String }

newtype Test a = Test (ReaderT Env IO (Maybe a))

io :: IO a -> Test a
io = liftIO

atomicLogger :: IO (String -> IO ())
atomicLogger = do
  lock <- newMVar ()
  pure $ \msg ->
    -- force msg before acquiring lock
    let dummy = foldl' (\_ ch -> ch == 'a') True msg
    in dummy `seq` bracket (takeMVar lock) (\_ -> putMVar lock ()) (\_ -> putStrLn msg)

expect :: HasCallStack => Bool -> Test ()
expect False = crash "unexpected"
expect True = ok

expectJust :: HasCallStack => Maybe a -> Test a
expectJust Nothing = crash "expected Just, got Nothing"
expectJust (Just a) = ok >> pure a

expectRight :: HasCallStack => Either e a -> Test a
expectRight (Left _) = crash "expected Right, got Left"
expectRight (Right a) = ok >> pure a

tests :: [Test ()] -> Test ()
tests = msum

-- | Run all tests whose scope starts with the given prefix
runOnly :: String -> Test a -> IO ()
runOnly prefix t = do
  logger <- atomicLogger
  seed <- abs <$> Random.randomIO :: IO Int
  run' seed logger prefix t

-- | Run all tests with the given seed and whose scope starts with the given prefix
rerunOnly :: Int -> String -> Test a -> IO ()
rerunOnly seed prefix t = do
  logger <- atomicLogger
  run' seed logger prefix t

run :: Test a -> IO ()
run = runOnly ""

rerun :: Int -> Test a -> IO ()
rerun seed = rerunOnly seed []

run' :: Int -> (String -> IO ()) -> String -> Test a -> IO ()
run' seed note allow (Test t) = do
  let !rng = Random.mkStdGen seed
  resultsQ <- atomically (newTBQueue 50)
  rngVar <- newTVarIO rng
  note $ "Randomness seed for this run is " ++ show seed ++ ""
  results <- atomically $ newTVar Map.empty
  rs <- A.async . forever $ do
    -- note, totally fine if this bombs once queue is empty
    Just result <- atomically $ readTBQueue resultsQ
    (msgs, passed) <- atomically $ takeTMVar result
    atomically $ modifyTVar results (Map.insertWith combineStatus msgs passed)
    resultsMap <- readTVarIO results
    case Map.findWithDefault Skipped msgs resultsMap of
      Skipped -> pure ()
      Passed n -> note $ "OK " ++ (if n <= 1 then msgs else "(" ++ show n ++ ") " ++ msgs)
      Failed -> note $ "FAILED " ++ msgs
  let line = "------------------------------------------------------------"
  note "Raw test output to follow ... "
  note line
  e <- try (runReaderT (void t) (Env rngVar [] resultsQ note allow)) :: IO (Either SomeException ())
  case e of
    Left e -> note $ "Exception while running tests: " ++ show e
    Right () -> pure ()
  atomically $ writeTBQueue resultsQ Nothing
  _ <- A.waitCatch rs
  resultsMap <- readTVarIO results
  let
    resultsList = Map.toList resultsMap
    succeededList = [ n | (_, Passed n) <- resultsList ]
    succeeded = length succeededList
    -- totalTestCases = foldl' (+) 0 succeededList
    failures = [ a | (a, Failed) <- resultsList ]
    failed = length failures
  case failures of
    [] -> do
      note line
      case succeeded of
        0 -> do
          note "😶  hmm ... no test results recorded"
          note "Tip: use `ok`, `expect`, or `crash` to record results"
          note "Tip: if running via `runOnly` or `rerunOnly`, check for typos"
        1 -> note $ "✅  1 test passed, no failures! 👍 🎉"
        _ -> note $ "✅  " ++ show succeeded ++ " tests passed, no failures! 👍 🎉"
    (hd:_) -> do
      note line
      note "\n"
      note $ "  " ++ show succeeded ++ (if failed == 0 then " PASSED" else " passed")
      note $ "  " ++ show (length failures) ++ (if failed == 0 then " failed" else " FAILED (failed scopes below)")
      note $ "    " ++ intercalate "\n    " (map show failures)
      note ""
      note $ "  To rerun with same random seed:\n"
      note $ "    EasyTest.rerun " ++ show seed
      note $ "    EasyTest.rerunOnly " ++ show seed ++ " " ++ "\"" ++ hd ++ "\""
      note "\n"
      note line
      note "❌"
      exitWith (ExitFailure 1)

-- | Label a test. Can be nested. A `'.'` is placed between nested
-- scopes, so `scope "foo" . scope "bar"` is equivalent to `scope "foo.bar"`
scope :: String -> Test a -> Test a
scope msg (Test t) = Test $ do
  env <- ask
  let messages' = case messages env of [] -> msg; ms -> ms ++ ('.':msg)
  case (null (allow env) || take (length (allow env)) msg `isPrefixOf` allow env) of
    False -> putResult Skipped >> pure Nothing
    True -> liftIO $ runReaderT t (env { messages = messages', allow = drop (length msg + 1) (allow env) })

-- | Log a message
note :: String -> Test ()
note msg = do
  note_ <- asks note_
  liftIO $ note_ msg
  pure ()

-- | Log a showable value
note' :: Show s => s -> Test ()
note' = note . show

-- | Generate a random value
random :: Random a => Test a
random = do
  rng <- asks rng
  liftIO . atomically $ do
    rng0 <- readTVar rng
    let (a, rng1) = Random.random rng0
    writeTVar rng rng1
    pure a

-- | Generate a bounded random value. Inclusive on both sides.
random' :: Random a => a -> a -> Test a
random' lower upper = do
  rng <- asks rng
  liftIO . atomically $ do
    rng0 <- readTVar rng
    let (a, rng1) = Random.randomR (lower,upper) rng0
    writeTVar rng rng1
    pure a

bool :: Test Bool
bool = random

word8 :: Test Word8
word8 = random

-- | Generate a random `Char`
char :: Test Char
char = random

-- | Generate a random `Int`
int :: Test Int
int = random

-- | Generate a random `Double`
double :: Test Double
double = random

-- | Generate a random `Word`
word :: Test Word
word = random

-- | Generate a random `Int` in the given range
-- Note: `int' 0 5` includes both `0` and `5`
int' :: Int -> Int -> Test Int
int' = random'

-- | Generate a random `Char` in the given range
-- Note: `char' 'a' 'z'` includes both `'a'` and `'z'`.
char' :: Char -> Char -> Test Char
char' = random'

-- | Generate a random `Double` in the given range
-- Note: `double' 0 1` includes both `0` and `1`.
double' :: Double -> Double -> Test Double
double' = random'

-- | Generate a random `Double` in the given range
-- Note: `word' 0 10` includes both `0` and `10`.
word' :: Word -> Word -> Test Word
word' = random'

-- | Generate a random `Double` in the given range
-- Note: `word8' 0 10` includes both `0` and `10`.
word8' :: Word8 -> Word8 -> Test Word8
word8' = random'

-- | Sample uniformly from the given list of possibilities
pick :: [a] -> Test a
pick as = let n = length as; ind = picker n as in do
  i <- int' 0 (n - 1)
  Just a <- pure (ind i)
  pure a

picker :: Int -> [a] -> (Int -> Maybe a)
picker _ [] = const Nothing
picker _ [a] = \i -> if i == 0 then Just a else Nothing
picker size as = go where
  lsize = size `div` 2
  rsize = size - lsize
  (l,r) = splitAt lsize as
  lpicker = picker lsize l
  rpicker = picker rsize r
  go i = if i < lsize then lpicker i else rpicker (i - lsize)

-- | Alias for `replicateM`
listOf :: Int -> Test a -> Test [a]
listOf = replicateM

-- | Generate a list of lists of the given sizes,
-- an alias for `sizes `forM` \n -> listOf n gen`
listsOf :: [Int] -> Test a -> Test [[a]]
listsOf sizes gen = sizes `forM` \n -> listOf n gen

-- | Alias for `liftA2 (,)`.
pair :: Test a -> Test b -> Test (a,b)
pair = liftA2 (,)

-- | Generate a `Data.Map k v` of the given size.
mapOf :: Ord k => Int -> Test k -> Test v -> Test (Map k v)
mapOf n k v = Map.fromList <$> listOf n (pair k v)

-- | Generate a `[Data.Map k v]` of the given sizes.
mapsOf :: Ord k => [Int] -> Test k -> Test v -> Test [Map k v]
mapsOf sizes k v = sizes `forM` \n -> mapOf n k v

-- | Catch all exceptions that could occur in the given `Test`
wrap :: Test a -> Test a
wrap (Test t) = Test $ do
  env <- ask
  lift $ runWrap env t

runWrap :: Env -> ReaderT Env IO (Maybe a) -> IO (Maybe a)
runWrap env t = do
  e <- liftIO . try $ runReaderT t env
  case e of
    Left e -> do
      note_ env (messages env ++ " EXCEPTION: " ++ show (e :: SomeException))
      pure Nothing
    Right a -> pure a

-- | A test with a setup and teardown
using :: IO r -> (r -> IO ()) -> (r -> Test a) -> Test a
using r cleanup use = Test $ do
  r <- liftIO r
  env <- ask
  let Test t = use r
  a <- liftIO (runWrap env t)
  liftIO (cleanup r)
  pure a

-- | The current scope
currentScope :: Test String
currentScope = asks messages

-- | Prepend the current scope to a logging message
noteScoped :: String -> Test ()
noteScoped msg = do
  s <- currentScope
  note (s ++ (if null s then "" else " ") ++ msg)

-- | Record a successful test at the current scope
ok :: Test ()
ok = Test (Just <$> putResult (Passed 1))

-- | Explicitly skip this test
skip :: Test ()
skip = Test (Nothing <$ putResult Skipped)

-- | Record a failure at the current scope
crash :: HasCallStack => String -> Test a
crash msg = do
  let trace = callStack
      msg' = msg ++ " " ++ prettyCallStack trace
  Test (Just <$> putResult Failed) >> noteScoped ("FAILURE " ++ msg') >> Test (pure Nothing)

putResult :: Status -> ReaderT Env IO ()
putResult passed = do
  msgs <- asks messages
  allow <- asks (null . allow)
  r <- liftIO . atomically $ newTMVar (msgs, if allow then passed else Skipped)
  q <- asks results
  lift . atomically $ writeTBQueue q (Just r)

instance MonadReader Env Test where
  ask = Test $ do
    allow <- asks (null . allow)
    case allow of
      True -> Just <$> ask
      False -> pure Nothing
  local f (Test t) = Test (local f t)
  reader f = Test (Just <$> reader f)

instance Monad Test where
  fail = crash
  return a = Test $ do
    allow <- asks (null . allow)
    pure $ case allow of
      True -> Just a
      False -> Nothing
  Test a >>= f = Test $ do
    a <- a
    case a of
      Nothing -> pure Nothing
      Just a -> let Test t = f a in t

instance Functor Test where
  fmap = liftM

instance Applicative Test where
  pure = return
  (<*>) = ap

instance MonadIO Test where
  liftIO io = do
    s <- asks (null . allow)
    case s of
      True -> wrap $ Test (Just <$> liftIO io)
      False -> Test (pure Nothing)

instance Alternative Test where
  empty = Test (pure Nothing)
  Test t1 <|> Test t2 = Test $ do
    env <- ask
    (rng1, rng2) <- liftIO . atomically $ do
      currentRng <- readTVar (rng env)
      let (rng1, rng2) = Random.split currentRng
      (,) <$> newTVar rng1 <*> newTVar rng2
    lift $ do
      _ <- runWrap (env { rng = rng1 }) t1
      runWrap (env { rng = rng2 }) t2

instance MonadPlus Test where
  mzero = empty
  mplus = (<|>)

-- | Run a test in a separate thread, not blocking for its result.
fork :: Test a -> Test ()
fork t = void (fork' t)

-- | Run a test in a separate thread, return a future which can be used
-- to block on its result.
fork' :: Test a -> Test (Test a)
fork' (Test t) = do
  env <- ask
  tmvar <- liftIO newEmptyTMVarIO
  liftIO . atomically $ writeTBQueue (results env) (Just tmvar)
  r <- liftIO . A.async $ runWrap env t
  waiter <- liftIO . A.async $ do
    e <- A.waitCatch r
    _ <- atomically $ tryPutTMVar tmvar (messages env, Skipped)
    case e of
      Left _ -> pure Nothing
      Right a -> pure a
  pure $ do
    a <- liftIO (A.wait waiter)
    case a of Nothing -> empty
              Just a -> pure a
