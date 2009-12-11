{-# LANGUAGE TypeSynonymInstances #-}
-- |
-- Module      : System.Linux.Epoll.Buffer
-- Copyright   : (c) 2009 Toralf Wittner
-- License     : LGPL
-- Maintainer  : toralf.wittner@gmail.com
-- Stability   : experimental
-- Portability : non-portable
--
-- Buffer layer above epoll. Implemented using 'EventLoop's.
-- The general usage is that first an instance of 'Runtime' is obtained, then
-- one creates as many buffers as needed. Once done with a buffer, it has 
-- to be closed and finally the runtime should be shutdown, which kills 
-- the event loop, e.g.
--
-- @
-- do r <- createRuntime (fromJust . toSize $ 4096)
--    withIBuffer r stdInput $ \\b ->
--        readBuffer b >>= mapM_ print . take 10 . lines
--    shutdownRuntime r
-- @
--
-- Please note that one has to close all buffers before calling shutdown on
-- the runtime.

module System.Linux.Epoll.Buffer (
    
    Runtime,
    createRuntime,
    shutdownRuntime,

    BufElem (..),

    IBuffer,
    createIBuffer,
    closeIBuffer,
    withIBuffer,
    
    OBuffer,
    createOBuffer,
    closeOBuffer,
    withOBuffer,

    readBuffer,
    readAvail,
    readChunk,
    writeBuffer,
    flushBuffer

) where

import BChan
import Prelude
import Data.Maybe
import Control.Monad
import Control.Exception (bracket)
import System.Posix.Types (Fd)
import System.IO (hPrint, stderr)
import System.Posix.IO (fdRead, fdWrite)
import System.Linux.Epoll.Base
import System.Linux.Epoll.EventLoop

-- | Buffer Element type class.
-- Any instance of this class can be used as a buffer element.
class BufElem a where
    -- | Zero element, e.g. empty string.
    beZero   :: a
    -- | Concatenates multiple elements.
    beConcat :: [a] -> a
    -- | The length of one element.
    beLength :: a -> Int
    -- | Returns element minus integer.
    beDrop   :: Int -> a -> a
    -- | Writes element to 'Fd', returns written length.
    beWrite :: Fd -> a -> IO Int
    -- | Reads element of given length, returns element and actual length.
    beRead  :: Fd -> Int -> IO (a, Int)

instance BufElem String where
    beZero   = ""
    beConcat = concat
    beLength = length
    beDrop   = drop

    beWrite fd = liftM fromIntegral . fdWrite fd
    beRead  fd n = do
        (s, k) <- fdRead fd (fromIntegral n)
        return (s, fromIntegral k)

data Buffer a = Buffer {
        bufferChan  :: BChan (Maybe a),
        bufferCBack :: Callback
    }

-- | Buffer for reading after 'inEvent'.
newtype IBuffer a = IBuffer (Buffer a)

-- | Buffer for writing after 'outEvent'.
newtype OBuffer a = OBuffer (Buffer a)

-- | Abstract data type for buffer runtime support.
data Runtime = Runtime {
        rtILoop :: EventLoop,
        rtOLoop :: EventLoop
    }

-- | Creates a runtime instance where size denotes the epoll
-- device size (cf. 'create').
createRuntime :: Size -> IO Runtime
createRuntime s = do
    iloop <- createEventLoop s
    oloop <- createEventLoop s
    return $ Runtime iloop oloop

-- | Stops event processing and closes this runtime (and the 
-- underlying epoll device).
shutdownRuntime :: Runtime -> IO ()
shutdownRuntime rt = do
    stopEventLoop (rtILoop rt)
    stopEventLoop (rtOLoop rt)

-- | Create buffer for 'inEvent's.
createIBuffer :: BufElem a => Runtime -> Fd -> IO (IBuffer a)
createIBuffer rt fd = do
    chan <- newBChan
    let emap = [(inEvents, handleRead chan), (closeEvents, handleClose chan)]
    cb <- addCallback (rtILoop rt) fd emap
    return $ IBuffer (Buffer chan cb)

-- | Create Buffer for 'outEvent's.
createOBuffer :: BufElem a => Runtime -> Fd -> IO (OBuffer a)
createOBuffer rt fd = do
    chan <- newBChan
    let emap = [(outEvents, handleWrite chan), (closeEvents, handleClose chan)]
    cb <- addCallback (rtOLoop rt) fd emap
    return $ OBuffer (Buffer chan cb)

-- | Close an IBuffer. Must not be called after 'shutdownRuntime' has been
-- invoked.
closeIBuffer :: BufElem a => Runtime -> IBuffer a -> IO ()
closeIBuffer rt (IBuffer b) = do
    writeBChan (bufferChan b) Nothing
    removeCallback (rtILoop rt) (bufferCBack b)

-- | Close an OBuffer. Must not be called after 'shutdownRuntime' has been
-- invoked.
closeOBuffer :: BufElem a => Runtime -> OBuffer a -> IO ()
closeOBuffer rt (OBuffer b) = do
    writeBChan (bufferChan b) Nothing
    removeCallback (rtOLoop rt) (bufferCBack b)

-- | Exception safe wrapper which creates an IBuffer, passes it to the provided
-- function and closes it afterwards.
withIBuffer :: BufElem a => Runtime -> Fd -> (IBuffer a -> IO b) -> IO b
withIBuffer r fd = bracket (createIBuffer r fd) (closeIBuffer r)

-- | Exception safe wrapper which creates an OBuffer, passes it to the provided
-- function and flushes and closes it afterwards.
withOBuffer :: BufElem a => Runtime -> Fd -> (OBuffer a -> IO b) -> IO b
withOBuffer r fd f = bracket (createOBuffer r fd) (closeOBuffer r) $ \b ->
    f b >>= \v -> flushBuffer b >> return v

-- | Blocking read. Lazily returns all available contents from 'IBuffer'.
readBuffer :: BufElem a => IBuffer a -> IO a
readBuffer (IBuffer b) = liftM (beConcat . map fromJust . takeWhile isJust) $
    getBChanContents (bufferChan b)

-- | Blocking read. Returns one chunk from 'IBuffer'.
readChunk :: BufElem a => IBuffer a -> IO a
readChunk (IBuffer b) = liftM (fromMaybe beZero) $ readBChan (bufferChan b)

-- | Non-Blocking read. Returns one chunk if available.
readAvail :: BufElem a => IBuffer a -> IO (Maybe a)
readAvail (IBuffer b) = do
    let ch = bufferChan b
    empty <- isEmptyBChan ch
    if empty then readBChan ch else return Nothing

-- | Non-Blocking write. Writes value to buffer which will asynchronously be
-- written to file descriptor.
writeBuffer :: BufElem a => OBuffer a -> a -> IO ()
writeBuffer (OBuffer b) = writeBChan (bufferChan b) . Just

-- | Blocks until buffer is emptied.
flushBuffer :: OBuffer a -> IO ()
flushBuffer (OBuffer b) = waitBChan (bufferChan b)

--
-- Event handling
--

handleClose :: BufElem a => BChan (Maybe a) -> Device -> Event Data -> IO ()
handleClose ch _ _ = writeBChan ch Nothing -- Ensure blocking ops finish.

handleRead :: BufElem a => BChan (Maybe a) -> Device -> Event Data -> IO ()
handleRead cha dev e = do
    doRead cha (eventFd e)
    reEnableCallback dev (eventRef e) (eventDesc e)
 where
    doRead :: BufElem a => BChan (Maybe a) -> Fd -> IO ()
    doRead ch fd = do
        (s, k) <- beRead fd defaultBlockSize `catch` \er ->
                    logErr er >> return (beZero, 0)
        unless (k == 0) $
            writeBChan ch (Just s)
        when (k == defaultBlockSize) $
            doRead ch fd

handleWrite :: BufElem a => BChan (Maybe a) -> Device -> Event Data -> IO ()
handleWrite cha dev e = doWrite cha (eventFd e)
 where
    doWrite :: BufElem a => BChan (Maybe a) -> Fd -> IO ()
    doWrite ch fd = do
        s <- peekBChan ch
        case s of
            Just s' -> do
                k <- beWrite fd s' `catch` \er -> logErr er >> return 0
                if k == beLength s'
                    then do dropBChan ch
                            doWrite ch fd
                    else do unGetBChan ch (Just (beDrop k s'))
                            reEnableCallback dev (eventRef e) (eventDesc e)
            Nothing -> return ()

defaultBlockSize :: Int
defaultBlockSize = 8192

logErr :: (Show a) => a -> IO ()
logErr = hPrint stderr

inEvents :: EventType
inEvents = combineEvents [inEvent, edgeTriggeredEvent, oneShotEvent]

outEvents :: EventType
outEvents = combineEvents [outEvent, edgeTriggeredEvent, oneShotEvent]

