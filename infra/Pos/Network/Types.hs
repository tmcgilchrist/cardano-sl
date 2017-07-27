module Pos.Network.Types
    ( NetworkConfig (..)
    , Topology(..)
    , SubscriptionWorker(..)
    , topologyNodeType
    , topologySubscriberNodeType
    , topologySubscriptionWorker
    , topologyRunKademlia
    , resolveDnsDomains
    , defaultNetworkConfig
    , staticallyKnownPeers
    , initQueue
      -- * Re-exports
      -- ** from .DnsDomains
    , DnsDomains(..)
    , DNSError
      -- ** from time-warp
    , NodeType (..)
    , MsgType (..)
    , Origin (..)
      -- ** other
    , NodeId (..)
    ) where

import           Universum
import           Data.IP (IPv4)
import           Network.Broadcast.OutboundQueue.Types
import           Network.Broadcast.OutboundQueue (OutboundQ)
import qualified Network.Broadcast.OutboundQueue as OQ
import           Node.Internal (NodeId (..))
import           Pos.Network.DnsDomains (DnsDomains(..), DNSError)
import           Pos.Network.Yaml (NodeName(..))
import           Pos.Util.TimeWarp  (addressToNodeId)
import qualified Pos.Network.DnsDomains as DnsDomains
import qualified Data.ByteString.Char8  as BS.C8
import           Pos.DHT.Real.Param (KademliaParams (..))

-- | Information about the network in which a node participates.
data NetworkConfig = NetworkConfig
    { ncTopology :: !Topology
      -- ^ Network topology from the point of view of the current node
    , ncKademlia :: !(Maybe KademliaParams)
      -- ^ Kademlia instance description if applicable.
    , ncDefaultPort :: !Word16
      -- ^ Port number to use when translating IP addresses to NodeIds
    , ncSelfName :: !(Maybe NodeName)
      -- ^ Our node name (if known)
    }
  deriving (Show)

defaultNetworkConfig :: Topology -> NetworkConfig
defaultNetworkConfig ncTopology = NetworkConfig {
      ncDefaultPort = 3000
    , ncKademlia    = Nothing
    , ncSelfName    = Nothing
    , ..
    }

-- | Topology of the network, from the point of view of the current node
data Topology =
    -- | All peers of the node have been statically configured
    --
    -- This is used for core and relay nodes
    TopologyStatic !NodeType !(Peers NodeId)

    -- | We discover our peers through DNS
    --
    -- This is used for behind-NAT nodes.
  | TopologyBehindNAT !DnsDomains

    -- | We discover our peers through Kademlia
  | TopologyP2P

    -- | We discover our peers through Kademlia, and every node in the network
    -- is a core node.
  | TopologyTraditional

    -- | Light wallets simulate "real" edge nodes, but are configured with
    -- a static set of relays.
  | TopologyLightWallet [NodeId]
  deriving (Show)

-- | Derive node type from its topology
topologyNodeType :: Topology -> NodeType
topologyNodeType (TopologyStatic nodeType _) = nodeType
topologyNodeType (TopologyBehindNAT _)       = NodeEdge
topologyNodeType (TopologyP2P)               = NodeEdge
topologyNodeType (TopologyTraditional)       = NodeCore
topologyNodeType (TopologyLightWallet _)     = NodeEdge

-- | The NodeType to assign to subscribers. Give Nothing if subscribtion
-- is not allowed for a node with this topology.
topologySubscriberNodeType :: Topology -> Maybe NodeType
topologySubscriberNodeType (TopologyStatic NodeRelay _) = Just NodeEdge
topologySubscriberNodeType (TopologyTraditional)        = Just NodeCore
topologySubscriberNodeType (TopologyP2P)                = Just NodeRelay
topologySubscriberNodeType _                            = Nothing

data SubscriptionWorker =
    SubscriptionWorkerBehindNAT DnsDomains
  | SubscriptionWorkerKademlia

-- | What kind of subscription worker do we run?
topologySubscriptionWorker :: Topology -> Maybe SubscriptionWorker
topologySubscriptionWorker = go
  where
    go (TopologyBehindNAT doms) = Just $ SubscriptionWorkerBehindNAT doms
    go (TopologyP2P)            = Just $ SubscriptionWorkerKademlia
    go (TopologyTraditional)    = Just $ SubscriptionWorkerKademlia
    go _otherwise               = Nothing

-- | Should we register to the Kademlia network?
topologyRunKademlia :: Topology -> Bool
topologyRunKademlia = go
  where
    go (TopologyStatic NodeRelay _) = True
    go (TopologyStatic _ _)         = False
    go (TopologyBehindNAT _)        = False
    go (TopologyP2P)                = True
    go (TopologyTraditional)        = True
    go (TopologyLightWallet _)      = False

-- | Variation on resolveDnsDomains that returns node IDs
resolveDnsDomains :: NetworkConfig
                  -> DnsDomains
                  -> IO (Either [DNSError] [NodeId])
resolveDnsDomains NetworkConfig{..} dnsDomains =
    fmap (map ipv4ToNodeId) <$> DnsDomains.resolveDnsDomains dnsDomains
  where
    -- | Turn IPv4 address returned by DNS into a NodeId
    ipv4ToNodeId :: IPv4 -> NodeId
    ipv4ToNodeId addr = addressToNodeId (BS.C8.pack (show addr), ncDefaultPort)

-- | All statically known peers
staticallyKnownPeers :: NetworkConfig -> Peers NodeId
staticallyKnownPeers NetworkConfig{..} = go ncTopology
  where
    go :: Topology -> Peers NodeId
    go (TopologyStatic _selfType peers) = peers
    go (TopologyBehindNAT _)            = mempty
    go (TopologyP2P)                    = mempty
    go (TopologyTraditional)            = mempty
    go (TopologyLightWallet peers)      = simplePeers $ map (NodeRelay, ) peers

-- | Initialize the outbound queue based on the network configuration
--
-- We add all statically known peers to the queue, so that we know to send
-- messages to those peers. This is relevant only for core nodes and
-- light wallets. In the former case, those core nodes will in turn add this
-- core node to /their/ outbound queue because this node would equally be
-- a statically known peer; in the latter case, light wallets are not expected
-- to receive any messages so messages in the reverse direction don't matter.
--
-- For behind NAT nodes and Kademlia nodes (P2P or traditional) we start
-- (elsewhere) specialized workers that add peers to the queue and subscribe
-- to (some of) those peers.
initQueue :: FormatMsg msg => NetworkConfig -> IO (OutboundQ msg NodeId)
initQueue cfg@NetworkConfig{..} = do
    oq <- OQ.new selfName enqueuePolicy dequeuePolicy failurePolicy
    OQ.addKnownPeers oq (staticallyKnownPeers cfg)
    return oq
  where
    ourNodeType   = topologyNodeType ncTopology
    selfName      = fromMaybe "self" ncSelfName
    enqueuePolicy = OQ.defaultEnqueuePolicy ourNodeType
    dequeuePolicy = OQ.defaultDequeuePolicy ourNodeType
    failurePolicy = OQ.defaultFailurePolicy ourNodeType
