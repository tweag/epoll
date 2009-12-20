{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
-- |
-- Module      : BChan
-- Copyright   : (c) 2009 Toralf Wittner
-- License     : LGPL
-- Maintainer  : toralf.wittner@gmail.com
-- Stability   : internal
-- Portability : portable
--
-- Internal helper module. Similar to 'Chan' but with support for blocking waits
-- until a buffer is empty.

module BChan where

import Data.IORef
import Control.Monad
import Control.Concurrent.MVar
import Control.Concurrent.Chan
import System.IO.Unsafe(unsafeInterleaveIO)

data BChan a = BChan {
        channel :: Chan a,
        counter :: IORef Int,
        rdrLock :: MVar (),
        waiting :: MVar [MVar ()]
    }

newBChan :: IO (BChan a)
newBChan = do
    c <- newChan
    n <- newIORef 0
    m <- newMVar ()
    w <- newMVar []
    return $ BChan c n m w

readBChan :: BChan a -> IO a
readBChan ch = withMVar (rdrLock ch) $ \_ -> do
    x <- readChan (channel ch)
    j <- atomicModifyIORef (counter ch) $ \i -> (i - 1, i - 1)
    when (j == 0) $
         modifyMVar_ (waiting ch) $ unblock . reverse
    return x

writeBChan :: BChan a -> a -> IO ()
writeBChan ch x = do
    writeChan (channel ch) x
    atomicModifyIORef (counter ch) $ \i -> (i + 1, i)
    return ()

peekBChan :: BChan a -> IO a
peekBChan ch = withMVar (rdrLock ch) $ \_ -> do
    x <- readChan (channel ch)
    unGetChan (channel ch) x
    return x

unGetBChan :: BChan a -> a -> IO ()
unGetBChan ch x = do
    unGetChan (channel ch) x
    atomicModifyIORef (counter ch) $ \i -> (i + 1, i)
    return ()

getBChanContents :: BChan a -> IO [a]
getBChanContents ch = unsafeInterleaveIO $ do
    x  <- readBChan ch
    xs <- getBChanContents ch
    return (x:xs)

waitBChan :: BChan a -> IO ()
waitBChan ch = do
    n <- readIORef (counter ch)
    unless (n == 0) $ do
        lock <- newEmptyMVar
        modifyMVar_ (waiting ch) $ return . (lock:)
        takeMVar lock

unblock :: [MVar ()] -> IO [MVar ()]
unblock = foldr (\m -> (>>) (putMVar m ())) (return [])

isEmptyBChan :: BChan a -> IO Bool
isEmptyBChan = isEmptyChan . channel

dropBChan :: BChan a -> IO ()
dropBChan ch = readBChan ch >> return ()

