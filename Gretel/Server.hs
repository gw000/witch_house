module Gretel.Server (startServer) where

import Control.Concurrent.STM
import Control.Monad
import GHC.Conc (forkIO, getNumCapabilities)
import Network
import System.IO

import Gretel.World
import Gretel.Interface
import Gretel.Server.Types
import Gretel.Server.Log
import Gretel.Server.Console
import Gretel.Version

startServer :: Options -> IO ()
startServer opts = do
  tmw <- atomically $ newTMVar (world opts)
  if not $ console opts
    then server opts tmw
    else do _ <- forkIO $ server opts tmw
            putStrLn $ "Gretel " ++ showVersion version
            putStrLn "Starting console..."
            startConsole opts tmw

-- | Accept connections on the designated port. For each connection,
-- fork off a process to forward its requests to the queue.
server :: Options -> TMVar World -> IO ()
server opts tmw = do
  sock <- listenOn $ PortNumber (fromIntegral . portNo $ opts)

  -- TODO: add a command line option for the format string.
  let logMsg = logger (logHandle opts) "%H:%M:%S %z" (verbosity opts)
  logMsg V1 $ "Listening on port " ++ show (portNo opts) ++ "."
  c <- getNumCapabilities
  logMsg V2 $ "Using up to " ++ show c ++ " cores."

  forever $ do
    (h,hn,p') <- accept sock
    forkIO $ session h hn p' tmw logMsg

session :: Handle -> HostName -> PortNumber -> TMVar World -> (Verbosity -> String -> IO ()) -> IO ()
session h hn p tmw logM = do
  logM V1 $ concat ["Connected: ", hn, ":", show p]
  res <- login h tmw

  case res of
    Left n -> do
      logM V2 $ hn ++ ":" ++ show p ++ " attempted to log in as " ++ n
    Right n -> do
      logM V2 $ hn ++ ":" ++ show p ++ " logged in as " ++ n
      serve h n tmw

  logM V1 $ concat ["Disconnected: ", hn, ":", show p]


login :: Handle -> TMVar World -> IO (Either String String)
login h tmw = do
  hPutStr h "What's yr name?? "
  n <- hGetLine h
  let greeting = hPutStrLn h $ "Hiya " ++ n ++ "!"
  w <- atomically $ takeTMVar tmw
  case getHandle n w of
    Nothing -> do greeting
                  let w' = if hasKey n w
                             then execWorld (setHandle' n h) w
                             -- TODO: set initial location in a sane way
                             else let ws = addKey' n >> setLoc' n "Root of the World" >> setHandle' n h
                                  in execWorld ws w
                  atomically $ putTMVar tmw w'
                  return $ Right n

    Just _ -> do atomically $ putTMVar tmw w
                 hPutStrLn h $ "Someone is already logged in as " ++ n ++". Please try again with a different handle."
                 hClose h
                 return $ Left n

serve :: Handle -> String -> TMVar World -> IO ()
serve h n tmw = do
  msg <- hGetLine h
  case msg of

    "quit" -> do hPutStrLn h "Bye!"
                 hClose h
                 w <- atomically $ takeTMVar tmw
                 let w' = execWorld (unsetHandle' n) w
                 atomically $ putTMVar tmw w'

    "" -> serve h n tmw

    _ -> do w <- atomically $ takeTMVar tmw
            let txt = unwords [quote n,msg]
                cmd  = parseCommand rootMap txt
                -- TODO: _correctly_ quote the name.
                quote s = "\"" ++ s ++ "\""
                (ns,w') = cmd w
            mapM_ (notify w') ns
            atomically $ putTMVar tmw w'
            serve h n tmw
                        

notify :: World -> Notification -> IO ()
notify w (Notify n msg) = when (not $ null msg) $ do
  case getHandle n w of
    Nothing -> return ()
    Just h -> hPutStrLn h msg

