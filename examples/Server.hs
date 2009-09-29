module Main where

import System.Linux.Epoll
import System.Posix.Types
import System.Environment
import System.IO
import Data.Maybe
import Text.Printf
import Control.Concurrent
import Control.Monad
import System.Posix.Signals
import Network.Socket
import Network.HTTP.Base
import Network.HTTP.Headers
import System.Time

main :: IO ()
main = getAndVerifyArgs >>= start . head

start :: String -> IO ()
start p = do
    epoll <- createRuntime (fromJust . toSize $ 8192)

    ai <- getAddrInfo (Just (defaultHints {addrFlags = [AI_PASSIVE]}))
                      Nothing 
                      (Just p)

    let serveraddr = head ai

    -- create server socket
    sock <- socket (addrFamily serveraddr) Stream defaultProtocol
    setSocketOption sock ReuseAddr 1

    -- bind it to the address we're listening to
    bindSocket sock (addrAddress serveraddr)

    printf "Listening at port %s\n" p

    -- start listening for connection requests max. connection requests waiting
    -- to be accepted = 5 (max. queue size)
    listen sock 256

    -- Ignore broken pipes
    installHandler sigPIPE Ignore Nothing

    -- accept connection requests (CTRL-C to abort)
    forever $ do
        (connsock, clientaddr) <- accept sock
        procRequest epoll connsock clientaddr

    shutdownRuntime epoll
 where
    procRequest :: Runtime -> Socket -> SockAddr -> IO ThreadId
    procRequest r sock' _ = forkIO $ do
        let fd = Fd $ fdSocket sock'
        withIBuffer r fd $ \ib -> do
            header <- readBuffer ib >>=
                return . parseRequestHead . takeWhile ("" /=) . breakLines
            case header of
                Left  e -> print $ "caught error: " ++ (show e)
                Right _ -> do
                    now <- getClockTime
                    let ts = show . calendarTimeToString . toUTCTime $ now
                        rs = response ts
                    withOBuffer r fd $ \ob -> do
                        writeBuffer ob (show rs)
                        writeBuffer ob (rspBody rs)
        sClose sock'

getAndVerifyArgs :: IO [String]
getAndVerifyArgs = do
    args <- getArgs
    when (length args /= 1)
         (error "Usage: Server <port>")
    return args

breakLines :: String -> [String]
breakLines str = pre : case rest of
    '\r':'\n':suf -> breakLines suf
    '\r':suf      -> breakLines suf
    '\n':suf      -> breakLines suf
    _             -> []
 where
    (pre, rest) = break (flip elem "\n\r") str

response :: String -> Response String
response s = Response (2, 0, 0) "OK"
    [Header HdrContentLength (show . length $ s)] s
