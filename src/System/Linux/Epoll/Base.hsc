{-# LANGUAGE CPP, ForeignFunctionInterface #-}
-- |
-- Module      : System.Linux.Epoll.Base
-- Copyright   : (c) 2009 Toralf Wittner
-- License     : LGPL
-- Maintainer  : toralf.wittner@gmail.com
-- Stability   : experimental
-- Portability : non-portable
-- 
-- Low level interface to Linux' epoll, a high performance polling mechanism
-- which handles high numbers of file descriptors efficiently. See man epoll(7)
-- for details.

module System.Linux.Epoll.Base (

    EventType,
    Size,
    toSize,
    Duration,
    toDuration,
    Descriptor,
    Device,
    Event (eventFd, eventType, eventRef, eventDesc),
    (=~),

    create,
    close,
    wait,

    add,
    modify,
    delete,
    freeDesc,

    inEvent,
    outEvent,
    peerCloseEvent,
    urgentEvent,
    errorEvent,
    hangupEvent,
    edgeTriggeredEvent,
    oneShotEvent,
    combineEvents

) where

import Util
import Foreign
import Foreign.C.Types (CInt (..))
import Foreign.C.Error (throwErrnoIfMinus1,
                        throwErrnoIfMinus1_,
                        throwErrnoIfMinus1Retry)
import System.Posix.Types (Fd (Fd))
import System.Posix.Signals (installHandler, sigPIPE, Handler (Ignore))

#include <sys/epoll.h>

-- | EventType corresponds to epoll's event type defines, e.g. EPOLLIN,
-- EPOLLOUT, EPOLLET, etc.
newtype EventType = EventType { fromEventType :: Int } deriving (Eq, Ord)

-- | Operation corresponds to epoll's EPOLL_CTL_ADD et al. It is the operation
-- designation in epoll_ctl.
newtype Operation = Operation { fromOp :: Int } deriving (Eq, Ord)

-- | Unsigned type used for length specifications.
newtype Size = Size { fromSize :: Word32 } deriving (Eq, Ord, Show)

-- | Unsigned type used for timeout specifications.
newtype Duration = Duration { fromDuration :: Word32 } deriving (Eq, Ord, Show)

-- | Event descriptor. Will be returned from 'add' and must be passed to
-- 'delete' exactly once.
newtype Descriptor a = Descriptor { descrPtr :: StablePtr (Fd, a) }

-- | Abstract epoll device. Holds internal data. Returned from 'create' and used
-- in almost every other API function. Must be closed explicitely with 'close'.
data Device = Device {
        deviceFd      :: !Fd,                -- ^ The epoll file descriptor.
        eventArray    :: !(Ptr EventStruct), -- ^ The event array used in 'wait'.
        eventArrayLen :: !Size               -- ^ The size of the event array.
    } deriving (Eq, Show)

-- | A single event ocurrence.
data Event a = Event {
        eventFd   :: !Fd,        -- ^ The file descriptor.
        eventType :: !EventType, -- ^ The event type.
        eventRef  :: !a,         -- ^ The user data as given in 'add'.
        eventDesc :: !(Descriptor a)
    }

-- | Representation of struct epoll_event.
data EventStruct = EventStruct {
        epollEvents :: !Word32,
        epollData   :: !(Ptr ())
    }

instance Storable EventStruct where
    alignment _ = #{alignment struct epoll_event}
    sizeOf _ = #{size struct epoll_event}
    peek p = do
        evts <- #{peek struct epoll_event, events} p
        dat  <- #{peek struct epoll_event, data} p
        return (EventStruct evts dat)
    poke p (EventStruct evts dat) = do
        #{poke struct epoll_event, events} p evts
        #{poke struct epoll_event, data} p dat

#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__); }, y__)

#{enum EventType, EventType,
    inEvent = EPOLLIN,
    outEvent = EPOLLOUT,
    peerCloseEvent = EPOLLRDHUP,
    urgentEvent = EPOLLPRI,
    errorEvent = EPOLLERR,
    hangupEvent = EPOLLHUP,
    edgeTriggeredEvent = EPOLLET,
    oneShotEvent = EPOLLONESHOT
}

instance Show EventType where
    show e | e == inEvent = "EPOLLIN (0x001)"
           | e == outEvent = "EPOLLOUT (0x004)"
           | e == peerCloseEvent = "EPOLLRDHUP (0x2000)"
           | e == urgentEvent = "EPOLLPRI (0x002)"
           | e == errorEvent = "EPOLLERR (0x008)"
           | e == hangupEvent = "EPOLLHUP (0x010)"
           | e == edgeTriggeredEvent = "EPOLLET (1 << 31)"
           | e == oneShotEvent = "EPOLLONESHOT (1 << 30)"
           | otherwise = show $ fromEventType e

#{enum Operation, Operation,
    addOp = EPOLL_CTL_ADD,
    modifyOp = EPOLL_CTL_MOD,
    deleteOp = EPOLL_CTL_DEL
}

instance Show Operation where
    show op | op == addOp    = "EPOLL_CTL_ADD"
            | op == modifyOp = "EPOLL_CTL_MOD"
            | op == deleteOp = "EPOLL_CTL_DEL"
            | otherwise = show $ fromOp op

-- | Creates an epoll device. Must be closed with 'close'.
-- The parameter 'Size' specifies the number of events that can be reported by a
-- single call to 'wait'.
create :: Size -> IO Device
create s = do
    dev <- throwErrnoIfMinus1 "create: c_epoll_create" (c_epoll_create 1)
    buf <- mallocArray (fromIntegral $ fromSize s)
    installHandler sigPIPE Ignore Nothing
    return $ Device (Fd dev) buf s

-- | Closes epoll device.
close :: Device -> IO ()
close = free . eventArray

-- | Adds a filedescriptor to the epoll watch set using the specified
-- EventTypes. User data might be passed in as well which will be returned on
-- event occurence as part of the 'Event' type. Returns an event descriptor
-- which must be deleted from the watch set with 'delete' and passed to
-- 'freeDesc' exactly once.
add :: Device -> a -> [EventType] -> Fd -> IO (Descriptor a)
add dev dat evts fd = do
    p <- newStablePtr (fd, dat)
    control dev addOp evts p
    return $ Descriptor p

-- | Modified the event types of the event descriptor.
modify :: Device -> [EventType] -> Descriptor a -> IO ()
modify dev evts des = control dev modifyOp evts (descrPtr des)

-- | Removes the event descriptor from the epoll watch set.
-- and frees descriptor which must not be used afterwards.
delete :: Device -> Descriptor a -> IO ()
delete dev des = control dev deleteOp [] (descrPtr des)

-- | Frees the resources associated with this descriptor.
-- Must be called exactly once.
freeDesc :: Descriptor a -> IO ()
freeDesc = freeStablePtr . descrPtr

-- | Representation of epoll_ctl.
control :: Device -> Operation -> [EventType] -> StablePtr (Fd, a) -> IO ()
control dev op evts ptr = do
    (fd, _) <- deRefStablePtr ptr
    throwErrnoIfMinus1_ (errMsg fd) $
        with (EventStruct (fromIntegral . fromEventType $ combineEvents evts)
                           (castStablePtrToPtr ptr))
             (c_epoll_ctl (intToNum $ deviceFd dev)
                          (fromIntegral $ fromOp op)
                          (intToNum fd))
 where
    errMsg fd = "control: c_epoll_ctl: fd=" ++ (show fd)
             ++ ", op=" ++ (show op)
             ++ ", events=" ++ (show evts)

-- | Waits for the specified duration on all event descriptors. Returns the
-- list of events that occured.
wait :: Duration -> Device -> IO [Event a]
wait timeout dev = do
    r <- throwErrnoIfMinus1Retry "wait: c_epoll_wait"
         (c_epoll_wait (intToNum $ deviceFd dev)
                       (eventArray dev)
                       (fromIntegral . fromSize $ eventArrayLen dev)
                       (fromIntegral $ fromDuration timeout))
    evts <- peekArray (fromIntegral r) (eventArray dev)
    mapM createEvent evts
 where
     createEvent e = do
        let ptr = castPtrToStablePtr $ epollData e
            ety = EventType (fromIntegral $ epollEvents e)
        (fd, ref) <- deRefStablePtr ptr
        return (Event fd ety ref (Descriptor ptr))

-- | Match operator. Useful to test whether an 'EventType' returned from
-- 'wait' contains one of the defined event types because EventTypes returned by
-- wait might be the bitwise OR of several EventTypes.
(=~) :: EventType -> EventType -> Bool
e1 =~ e2 = fromEventType e1 .&. fromEventType e2 /= 0

infix 4 =~

toSize :: Int -> Maybe Size
toSize i = toWord32 i >>= Just . Size

toDuration :: Int -> Maybe Duration
toDuration i = toWord32 i >>= Just . Duration

-- | Bitwise OR of the list of 'EventType's.
combineEvents :: [EventType] -> EventType
combineEvents = EventType . foldr ((.|.) . fromEventType) 0

-- Foreign Imports --

foreign import ccall unsafe "epoll.h epoll_create"
    c_epoll_create :: CInt -> IO CInt

foreign import ccall unsafe "epoll.h epoll_ctl"
    c_epoll_ctl :: CInt -> CInt -> CInt -> Ptr EventStruct -> IO CInt

foreign import ccall safe "epoll.h epoll_wait"
    c_epoll_wait :: CInt -> Ptr EventStruct -> CInt -> CInt -> IO CInt

