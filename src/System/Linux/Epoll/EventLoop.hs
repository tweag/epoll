{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
-- |
-- Module      : System.Linux.Epoll.EventLoop
-- Copyright   : (c) 2009 Toralf Wittner
-- License     : LGPL
-- Maintainer  : toralf.wittner@gmail.com
-- Stability   : experimental
-- Portability : non-portable
--
-- EventLoop's can be used to get notified when certain events occur on a file
-- descriptor. One can add callback functions for any 'EventType' combination.

module System.Linux.Epoll.EventLoop (

    Data,
    Callback,
    EventLoop,
    CallbackFn,
    EventMap,

    createEventLoop,
    stopEventLoop,
    addCallback,
    removeCallback,
    reEnableCallback,

    closeEvents

) where

import Util
import Control.Monad
import Control.Concurrent
import Data.Maybe
import System.Posix.Types (Fd)
import System.Linux.Epoll.Base
import System.Posix.IO (setFdOption, FdOption (NonBlockingRead))

-- | Callback function type
type CallbackFn = Device -> Event Data -> IO ()
type EventMap = [(EventType, CallbackFn)]

-- Used to queue up deleted descriptors to pass them to freeDesc.
--
-- The reason is that freeing descriptors is only safe while no event processing
-- takes place, otherwise delayed handler thread might still use the descriptor
-- or when free directly in 'doClose', it might be part of the next event set
-- still which would cause a segfault.
type Garbage = MVar [Descriptor Data]

data Data = Data {
        cbMap   :: EventMap,
        cbDirty :: MVar Bool -- True when closed.
    }

-- | Abstract data type holding bookeeping info.
data Callback = Callback {
        cbData :: Data,
        cbDesc :: Descriptor Data
    }

-- | Abstract data type.
data EventLoop = EventLoop {
        elDevice   :: Device,   -- Epoll Device
        elLoop     :: ThreadId, -- Epoll wait loop thread
        elGarbage  :: Garbage   -- Epoll Descriptors to be deleted
    }

-- | Create one event loop which handles up to 'Size' events per call to epoll's
-- 'wait'. An event loop runs until 'stopEventLoop' is invoked, calling 'wait'
-- with a max timeout of 500ms before it waits again.
createEventLoop :: Size -> IO EventLoop
createEventLoop s = do
    dev <- create s
    bin <- newMVar []
    lop <- forkIO $ runLoop dev bin
    return $ EventLoop dev lop bin

-- | Terminates the event loop and cleans resources. Note that one can only
-- remove callbacks from an eventloop while it is running, so make sure you call
-- this function after all 'removeCallback' calls.
stopEventLoop :: EventLoop -> IO ()
stopEventLoop el = do
    killThread (elLoop el)
    close (elDevice el)

-- | Adds a callback for the given file descriptor to this event loop. The event
-- map specifies for each event type which function to call. event types might
-- be combined using 'combineEvents'.
addCallback :: EventLoop -> Fd -> EventMap -> IO Callback
addCallback el fd emp = do
    dirty <- newMVar False
    let ety = map fst emp
        dat = Data emp dirty
    setFdOption fd NonBlockingRead True
    desc <- add (elDevice el) dat ety fd
    return $ Callback dat desc

-- | Removes the callback obtained from 'addCallback' from this event loop. Note
-- that you must not call 'stopEventLoop' before invoking this function.
removeCallback :: EventLoop -> Callback -> IO ()
removeCallback el cb = do
    doClose (elDevice el) (elGarbage el) (cbDesc cb) (cbData cb)
    return ()

-- | In case you use 'oneShotEvent' you can re-enable a callback after the event
-- occured. Otherwise no further events will be reported. Cf. epoll(7) for
-- details.
reEnableCallback :: Device -> Data -> Descriptor Data -> IO ()
reEnableCallback dev dat des =
    withMVar (cbDirty dat) $ \dirty ->
        unless dirty $
            modify dev (map fst (cbMap dat)) des

-- The heart of the event loop. Runs forever, dispatching events.
runLoop :: Device -> Garbage -> IO ()
runLoop dev bin = do
    let dur = fromJust . toDuration $ 500
    forever $ wait dur dev >>= mapM_ dispatch >> gc bin >> yield
 where
    dispatch e = case eventType e of
                    t | t =~ closeEvents -> handleClose dev bin e
                      | otherwise        -> handleEvent dev e

    -- garbage collection, i.e. free old descriptors
    gc b = modifyMVar b (\v -> return ([], v)) >>= mapM freeDesc

-- Invokes 'doClose' and potentially 'handleEvent' with 'closeEvents',
-- if the callback has not been closed before.
handleClose :: Device -> Garbage -> Event Data -> IO ()
handleClose dev bin e = do
    isDirty <- doClose dev bin (eventDesc e) (eventRef e)
    unless isDirty $ handleEvent dev (e { eventType = closeEvents })

-- Marks callback data as dirty and deletes descriptor, i.e. removes it from
-- epoll and schedules it for freeDesc.
doClose :: Device -> Garbage -> Descriptor Data -> Data -> IO Bool
doClose dev bin des dat =
    modifyMVar (cbDirty dat) $ \dirty -> do
        unless dirty $ do
            delete dev des
            modifyMVar_ bin $ return . (des:)
        return (True, dirty)

-- Forks each callback function which is applicable for the current
-- event into its own thread.
handleEvent :: Device -> Event Data -> IO ()
handleEvent dev e = do
    let fs = lookupCB (cbMap . eventRef $ e) (eventType e)
    forM_ fs $ \f -> forkIO_ $ f dev e

-- Matches the given event type against the event map.
lookupCB :: EventMap -> EventType -> [CallbackFn]
lookupCB emap ety = map snd $ filter ((=~ ety) . fst) emap

-- | A combination of 'peerCloseEvent', 'errorEvent', 'hangupEvent'.
closeEvents :: EventType
closeEvents = combineEvents [peerCloseEvent, errorEvent, hangupEvent]

