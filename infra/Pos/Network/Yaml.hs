-- | Infrastructure for parsing the .yaml network topology file

{-# LANGUAGE RankNTypes #-}

module Pos.Network.Yaml (
    Topology(..)
  , AllStaticallyKnownPeers(..)
  , DnsDomains(..)
  , KademliaParams(..)
  , KademliaId(..)
  , KademliaAddress(..)
  , NodeName(..)
  , NodeRegion(..)
  , NodeRoutes(..)
  , NodeMetadata(..)
  , RunKademlia
  , Valency
  , Fallbacks

  , StaticPolicies(..)
  , StaticEnqueuePolicy -- opaque
  , StaticDequeuePolicy -- opaque
  , StaticFailurePolicy -- opaque
  , fromStaticPolicies
  ) where

import           Data.Aeson             (FromJSON (..), ToJSON (..), (.!=),
                                         (.:), (.:?), (.=))
import qualified Data.Aeson             as A
import qualified Data.Aeson.Types       as A
import qualified Data.ByteString.Char8  as BS.C8
import qualified Data.HashMap.Lazy      as HM
import qualified Data.Map.Strict        as M
import           Network.Broadcast.OutboundQueue.Types
import qualified Network.Broadcast.OutboundQueue as OQ
import qualified Network.DNS            as DNS
import           Pos.Util.Config
import           Universum

import           Pos.Network.DnsDomains (DnsDomains (..), NodeAddr (..))

-- | Description of the network topology in a Yaml file
--
-- This differs from 'Pos.Network.Types.Topology' because for static nodes this
-- describes the entire network topology (all statically known nodes), not just
-- the topology from the point of view of the current node.
data Topology =
    TopologyStatic {
        topologyAllPeers :: !AllStaticallyKnownPeers
      }

  | TopologyBehindNAT {
        topologyValency    :: !Valency
      , topologyFallbacks  :: !Fallbacks
      , topologyDnsDomains :: !(DnsDomains (DNS.Domain))
      }

  | TopologyP2P {
        topologyValency   :: !Valency
      , topologyFallbacks :: !Fallbacks
      }

  | TopologyTraditional {
        topologyValency   :: !Valency
      , topologyFallbacks :: !Fallbacks
      }
  deriving (Show)

-- | The number of peers we want to send to
--
-- In other words, this should correspond to the length of the outermost lists
-- in the OutboundQueue's 'Peers' data structure.
type Valency = Int

-- | The number of fallbacks for each peer we want to send to
--
-- In other words, this should corresponding to one less than the length of the
-- innermost lists in the OutboundQueue's 'Peers' data structure.
type Fallbacks = Int

-- | All statically known peers in the newtork
data AllStaticallyKnownPeers = AllStaticallyKnownPeers {
    allStaticallyKnownPeers :: !(Map NodeName NodeMetadata)
  }
  deriving (Show)

newtype NodeName = NodeName Text
    deriving (Show, Ord, Eq, IsString)

instance ToString NodeName where
    toString (NodeName txt) = toString txt

newtype NodeRegion = NodeRegion Text
    deriving (Show, Ord, Eq, IsString)

newtype NodeRoutes = NodeRoutes [[NodeName]]
    deriving (Show)

data NodeMetadata = NodeMetadata
    { -- | Node type
      nmType    :: !NodeType

      -- | Region
    , nmRegion  :: !NodeRegion

      -- | Static peers of this node
    , nmRoutes  :: !NodeRoutes

      -- | Address for this node
    , nmAddress :: !(NodeAddr (Maybe DNS.Domain))

      -- | Should the node register itself with the Kademlia network?
    , nmKademlia :: !RunKademlia
    }
    deriving (Show)

type RunKademlia = Bool

-- | Parameters for Kademlia, in case P2P or traditional topology are used.
data KademliaParams = KademliaParams
    { kpId              :: !(Maybe KademliaId)
      -- ^ Kademlia identifier. Optional; one can be generated for you.
    , kpPeers           :: ![KademliaAddress]
      -- ^ Initial Kademlia peers, for joining the network.
    , kpAddress         :: !(Maybe KademliaAddress)
      -- ^ External Kadmelia address.
    , kpBind            :: !KademliaAddress
      -- ^ Address at which to bind the Kademlia socket.
      -- Shouldn't be necessary to have a separate bind and public address.
      -- The Kademlia instance in fact shouldn't even need to know its own
      -- address (should only be used to bind the socket). But due to the way
      -- that responses for FIND_NODES are serialized, Kademlia needs to know
      -- its own external address [TW-153]. The mainline 'kademlia' package
      -- doesn't suffer this problem.
    , kpExplicitInitial :: !Bool
    , kpDumpFile        :: !(Maybe FilePath)
    }
    deriving (Show)

instance FromJSON KademliaParams where
    parseJSON = A.withObject "KademliaParams" $ \obj -> do
        kpId <- obj .:? "identifier"
        kpPeers <- obj .: "peers"
        kpAddress <- obj .:? "externalAddress"
        kpBind <- obj .: "address"
        kpExplicitInitial <- obj .:? "explicitInitial" .!= False
        kpDumpFile <- obj .:? "dumpFile"
        return KademliaParams {..}

instance ToJSON KademliaParams where
    toJSON KademliaParams {..} = A.object [
          "identifier"      .= kpId
        , "peers"           .= kpPeers
        , "externalAddress" .= kpAddress
        , "address"         .= kpBind
        , "explicitInitial" .= kpExplicitInitial
        , "dumpFile"        .= kpDumpFile
        ]

-- | A Kademlia identifier in text representation (probably base64-url encoded).
newtype KademliaId = KademliaId String
    deriving (Show)

instance FromJSON KademliaId where
    parseJSON = fmap KademliaId . parseJSON

instance ToJSON KademliaId where
    toJSON (KademliaId txt) = toJSON txt

data KademliaAddress = KademliaAddress
    { kaHost :: !String
    , kaPort :: !Word16
    }
    deriving (Show)

instance FromJSON KademliaAddress where
    parseJSON = A.withObject "KademliaAddress " $ \obj ->
        KademliaAddress <$> obj .: "host" <*> obj .: "port"

instance ToJSON KademliaAddress where
    toJSON KademliaAddress {..} = A.object [
          "host" .= kaHost
        , "port" .= kaPort
        ]

{-------------------------------------------------------------------------------
  FromJSON instances
-------------------------------------------------------------------------------}

instance FromJSON NodeRegion where
  parseJSON = fmap NodeRegion . parseJSON

instance FromJSON NodeName where
  parseJSON = fmap NodeName . parseJSON

instance FromJSON NodeRoutes where
  parseJSON = fmap NodeRoutes . parseJSON

instance FromJSON NodeType where
  parseJSON = A.withText "NodeType" $ \typ -> do
      case toString typ of
        "core"     -> return NodeCore
        "edge"     -> return NodeEdge
        "relay"    -> return NodeRelay
        _otherwise -> fail $ "Invalid NodeType " ++ show typ

instance FromJSON OQ.Precedence where
  parseJSON = A.withText "Precedence" $ \typ -> do
      case toString typ of
        "lowest"  -> return OQ.PLowest
        "low"     -> return OQ.PLow
        "medium"  -> return OQ.PMedium
        "high"    -> return OQ.PHigh
        "highest" -> return OQ.PHighest
        _otherwise -> fail $ "Invalid Precedence" ++ show typ

instance FromJSON (DnsDomains DNS.Domain) where
  parseJSON = fmap DnsDomains . parseJSON

instance FromJSON (NodeAddr DNS.Domain) where
  parseJSON = A.withObject "NodeAddr" $ extractNodeAddr aux
    where
      aux :: Maybe DNS.Domain -> A.Parser DNS.Domain
      aux Nothing    = fail "Missing domain name or address"
      aux (Just dom) = return dom

-- Useful when we have a 'NodeAddr' as part of a larger object
extractNodeAddr :: (Maybe DNS.Domain -> A.Parser a)
                -> A.Object
                -> A.Parser (NodeAddr a)
extractNodeAddr mkA obj = do
    mAddr <- obj .:? "addr"
    mHost <- obj .:? "host"
    mPort <- obj .:? "port"
    case (mAddr, mHost) of
      (Just addr, Nothing) -> return $ NodeAddrExact (aux addr) mPort
      (Nothing,  _)        -> do a <- mkA (aux <$> mHost)
                                 return $ NodeAddrDNS a mPort
      (Just _, Just _)     -> fail "Cannot use both 'addr' and 'host'"
  where
    aux :: String -> DNS.Domain
    aux = BS.C8.pack

instance FromJSON NodeMetadata where
  parseJSON = A.withObject "NodeMetadata" $ \obj -> do
      nmType     <- obj .: "type"
      nmRegion   <- obj .: "region"
      nmRoutes   <- obj .: "static-routes"
      nmAddress  <- extractNodeAddr return obj
      nmKademlia <- obj .:? "kademlia" .!= defaultRunKademlia nmType
      return NodeMetadata{..}
   where
     defaultRunKademlia :: NodeType -> RunKademlia
     defaultRunKademlia NodeCore  = False
     defaultRunKademlia NodeRelay = True
     defaultRunKademlia NodeEdge  = False

instance FromJSON AllStaticallyKnownPeers where
  parseJSON = A.withObject "AllStaticallyKnownPeers" $ \obj ->
      AllStaticallyKnownPeers . M.fromList <$> mapM aux (HM.toList obj)
    where
      aux :: (Text, A.Value) -> A.Parser (NodeName, NodeMetadata)
      aux (name, val) = (NodeName name, ) <$> parseJSON val

instance FromJSON Topology where
  parseJSON = A.withObject "Topology" $ \obj -> do
      mNodes  <- obj .:? "nodes"
      mWallet <- obj .:? "wallet"
      mP2p    <- obj .:? "p2p"
      case (mNodes, mWallet, mP2p) of
        (Just nodes, Nothing, Nothing) ->
            TopologyStatic <$> parseJSON nodes
        (Nothing, Just wallet, Nothing) -> flip (A.withObject "wallet") wallet $ \walletObj -> do
            topologyDnsDomains <- walletObj .:  "relays"
            topologyValency    <- walletObj .:? "valency"   .!= 1
            topologyFallbacks  <- walletObj .:? "fallbacks" .!= 1
            return TopologyBehindNAT{..}
        (Nothing, Nothing, Just p2p) -> flip (A.withObject "P2P") p2p $ \p2pObj -> do
            variantTxt        <- p2pObj .: "variant"
            topologyValency   <- p2pObj .:? "valency"   .!= 3
            topologyFallbacks <- p2pObj .:? "fallbacks" .!= 1
            flip (A.withText "P2P variant") variantTxt $ \txt -> case txt of
              "traditional" -> return TopologyTraditional{..}
              "normal"      -> return TopologyP2P{..}
              _             -> fail "P2P variant: expected 'traditional' or 'normal'"
        _ ->
          fail "Topology: expected exactly one of 'nodes', 'relays', or 'p2p'"

instance IsConfig Topology where
  configPrefix = return Nothing

{-------------------------------------------------------------------------------
  Policies described in JSON/YAML.
-------------------------------------------------------------------------------}

-- | Policies described by a JSON/YAML.
data StaticPolicies = StaticPolicies {
      staticEnqueuePolicy :: StaticEnqueuePolicy
    , staticDequeuePolicy :: StaticDequeuePolicy
    , staticFailurePolicy :: StaticFailurePolicy
    }

-- | An enqueue policy which can be described by JSON/YAML.
newtype StaticEnqueuePolicy = StaticEnqueuePolicy {
      getStaticEnqueuePolicy :: forall nid . MsgType nid -> [OQ.Enqueue]
    }

-- | A dequeue policy which can be described by JSON/YAML.
newtype StaticDequeuePolicy = StaticDequeuePolicy {
      getStaticDequeuePolicy :: NodeType -> OQ.Dequeue
    }

newtype StaticFailurePolicy = StaticFailurePolicy {
      getStaticFailurePolicy :: forall nid. NodeType -> MsgType nid -> OQ.ReconsiderAfter
    }

fromStaticPolicies :: StaticPolicies
                   -> ( OQ.EnqueuePolicy nid
                      , OQ.DequeuePolicy
                      , OQ.FailurePolicy nid
                      )
fromStaticPolicies StaticPolicies{..} = (
      fromStaticEnqueuePolicy staticEnqueuePolicy
    , fromStaticDequeuePolicy staticDequeuePolicy
    , fromStaticFailurePolicy staticFailurePolicy
    )

fromStaticEnqueuePolicy :: StaticEnqueuePolicy -> OQ.EnqueuePolicy nid
fromStaticEnqueuePolicy = getStaticEnqueuePolicy

fromStaticDequeuePolicy :: StaticDequeuePolicy -> OQ.DequeuePolicy
fromStaticDequeuePolicy = getStaticDequeuePolicy

fromStaticFailurePolicy :: StaticFailurePolicy -> OQ.FailurePolicy nid
fromStaticFailurePolicy p nodeType = const . getStaticFailurePolicy p nodeType

{-------------------------------------------------------------------------------
  Common patterns in the .yaml file
-------------------------------------------------------------------------------}

data SendOrForward t = SendOrForward {
      send    :: !t
    , forward :: !t
    }

newtype ByMsgType t = ByMsgType {
      byMsgType :: forall nid. MsgType nid -> t
    }

newtype ByNodeType t = ByNodeType {
      byNodeType :: NodeType -> t
    }

instance FromJSON t => FromJSON (SendOrForward t) where
    parseJSON = A.withObject "SendOrForward" $ \obj -> do
        send    <- obj .: "send"
        forward <- obj .: "forward"
        return SendOrForward {..}

instance FromJSON t => FromJSON (ByMsgType t) where
    parseJSON = A.withObject "ByMsgType" $ \obj -> do
        announceBlockHeader <- obj .: "announceBlockHeader"
        requestBlockHeaders <- obj .: "requestBlockHeaders"
        requestBlocks       <- obj .: "requestBlocks"
        transaction         <- obj .: "transaction"
        mpc                 <- obj .: "mpc"
        return $ ByMsgType $ \msg -> case msg of
            MsgAnnounceBlockHeader _                 -> announceBlockHeader
            MsgRequestBlockHeaders                   -> requestBlockHeaders
            MsgRequestBlocks       _                 -> requestBlocks
            MsgTransaction         OriginSender      -> send transaction
            MsgTransaction         (OriginForward _) -> forward transaction
            MsgMPC                 OriginSender      -> send mpc
            MsgMPC                 (OriginForward _) -> forward mpc

instance FromJSON t => FromJSON (ByNodeType t) where
    parseJSON = A.withObject "ByNodeType" $ \obj -> do
        core  <- obj .: "core"
        relay <- obj .: "relay"
        edge  <- obj .: "edge"
        return $ ByNodeType $ \nodeType -> case nodeType of
            NodeCore  -> core
            NodeRelay -> relay
            NodeEdge  -> edge

{-------------------------------------------------------------------------------
  FromJSON instances
-------------------------------------------------------------------------------}

instance FromJSON StaticPolicies where
    parseJSON = A.withObject "StaticPolicies" $ \obj -> do
        staticEnqueuePolicy <- obj .: "enqueue"
        staticDequeuePolicy <- obj .: "dequeue"
        staticFailurePolicy <- obj .: "failure"
        return StaticPolicies {..}

instance FromJSON StaticEnqueuePolicy where
    parseJSON = fmap aux . parseJSON
      where
        aux :: ByMsgType [OQ.Enqueue] -> StaticEnqueuePolicy
        aux f = StaticEnqueuePolicy (byMsgType f)

instance FromJSON StaticDequeuePolicy where
    parseJSON = fmap aux . parseJSON
      where
        aux :: ByNodeType OQ.Dequeue -> StaticDequeuePolicy
        aux f = StaticDequeuePolicy (byNodeType f)

instance FromJSON StaticFailurePolicy where
    parseJSON = fmap aux . parseJSON
      where
        aux :: ByNodeType (ByMsgType OQ.ReconsiderAfter) -> StaticFailurePolicy
        aux f = StaticFailurePolicy (byMsgType . byNodeType f)

{-------------------------------------------------------------------------------
  Orphans
-------------------------------------------------------------------------------}

instance FromJSON OQ.Enqueue where
    parseJSON = A.withObject "Enqueue" $ \obj -> do
        mAll <- obj .:? "all"
        mOne <- obj .:? "one"
        case (mAll, mOne) of
            (Just all_, Nothing) -> parseEnqueueAll all_
            (Nothing, Just one_) -> parseEnqueueOne one_
            _ -> fail "Enqueue: expected 'one' or 'all', and not both."
      where
        parseEnqueueAll :: A.Object -> A.Parser OQ.Enqueue
        parseEnqueueAll obj = do
            nodeType   <- obj .: "nodeType"
            maxAhead   <- obj .: "maxAhead"
            precedence <- obj .: "precedence"
            return $ OQ.EnqueueAll {
                  enqNodeType   = nodeType
                , enqMaxAhead   = maxAhead
                , enqPrecedence = precedence
                }

        parseEnqueueOne :: A.Object -> A.Parser OQ.Enqueue
        parseEnqueueOne obj = do
            nodeTypes  <- obj .: "nodeTypes"
            maxAhead   <- obj .: "maxAhead"
            precedence <- obj .: "precedence"
            return $ OQ.EnqueueOne {
                  enqNodeTypes  = nodeTypes
                , enqMaxAhead   = maxAhead
                , enqPrecedence = precedence
                }

instance FromJSON OQ.Dequeue where
    parseJSON = A.withObject "Dequeue" $ \obj -> do
        deqRateLimit   <- obj .:? "rateLimit"   .!= OQ.NoRateLimiting
        deqMaxInFlight <- obj .:  "maxInFlight"
        return OQ.Dequeue {..}

instance FromJSON OQ.MaxAhead where
    parseJSON = fmap OQ.MaxAhead . parseJSON

instance FromJSON OQ.MaxInFlight where
    parseJSON = fmap OQ.MaxInFlight . parseJSON

instance FromJSON OQ.RateLimit where
    parseJSON = fmap OQ.MaxMsgPerSec . parseJSON

instance FromJSON OQ.ReconsiderAfter where
    parseJSON = fmap (OQ.ReconsiderAfter . fromInteger) . parseJSON
