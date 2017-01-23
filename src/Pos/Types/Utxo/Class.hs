{-# LANGUAGE TypeFamilies #-}

-- | Type class abstracting UTXO (set of unspent outputs).

module Pos.Types.Utxo.Class
       ( MonadUtxoRead (..)
       , MonadUtxo (..)
       ) where

import           Control.Monad.Except (ExceptT)
import           Control.Monad.Trans  (MonadTrans)
import           Universum

import           Pos.Types.Types      (TxIn, TxOutAux)

class Monad m => MonadUtxoRead m where
    utxoGet :: TxIn -> m (Maybe TxOutAux)
    default utxoGet :: (MonadTrans t, MonadUtxoRead m', t m' ~ m) => TxIn -> m (Maybe TxOutAux)
    utxoGet = lift . utxoGet

class MonadUtxoRead m => MonadUtxo m where
    utxoPut :: TxIn -> TxOutAux -> m ()
    default utxoPut :: (MonadTrans t, MonadUtxo m', t m' ~ m) => TxIn -> TxOutAux -> m ()
    utxoPut a = lift . utxoPut a
    utxoDel :: TxIn -> m ()
    default utxoDel :: (MonadTrans t, MonadUtxo m', t m' ~ m) => TxIn -> m ()
    utxoDel = lift . utxoDel

instance MonadUtxoRead m => MonadUtxoRead (ReaderT a m) where
instance MonadUtxo m => MonadUtxo (ReaderT e m) where

instance MonadUtxoRead m => MonadUtxoRead (ExceptT e m) where
instance MonadUtxo m => MonadUtxo (ExceptT e m) where

instance MonadUtxoRead m => MonadUtxoRead (StateT e m) where
instance MonadUtxo m => MonadUtxo (StateT e m) where
