module Main where

import System.Linux.Epoll
import System.Posix.IO
import System.IO
import Data.Maybe
import Text.Printf
import Control.Concurrent.MVar

eventTypes :: EventType
eventTypes = combineEvents [inEvent, edgeTriggeredEvent, oneShotEvent]

callback :: MVar () -> Device -> Event Data -> IO ()
callback lck d e = do
    let et = eventType e
        fd = eventFd e
    printf "event=%s, fd=%s\n" (show et) (show fd)
    (s, c) <- fdRead fd 16 `catch` \er -> print er >> return ("", 0)
    printf "read %s byte(s): %s\n" (show c) s
    if s == "quit\n"
        then putMVar lck ()
        else reEnableCallback d (eventRef e) (eventDesc e)

main :: IO ()
main = do
    let s = fromJust $ toSize 32
    lock <- newEmptyMVar
    loop <- createEventLoop s
    addCallback loop stdInput [(eventTypes, callback lock)]
    putStrLn "Enter 'quit' to exit."
    takeMVar lock

