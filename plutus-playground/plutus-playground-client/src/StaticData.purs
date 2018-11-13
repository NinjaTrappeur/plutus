module StaticData where

import Types

import Data.Either (Either(..))
import Data.Tuple (Tuple(..))
import Playground.API (Fn(..), FunctionSchema(..), SimpleArgumentSchema(..))

wallets :: Array Wallet
wallets =
  [ { walletId: WalletId "kris0001", balance: 10.0 }
  , { walletId: WalletId "david0001", balance: 23.0 }
  ]

editorContents :: String
editorContents = """-- | Vesting scheme as a PLC contract
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE ScopedTypeVariables         #-}
{-# LANGUAGE DeriveAnyClass         #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# OPTIONS -fplugin=Language.Plutus.CoreToPLC.Plugin -fplugin-opt Language.Plutus.CoreToPLC.Plugin:dont-typecheck #-}
module Contract where

import           Control.Monad.Error.Class  (MonadError (..))
import           Data.Aeson                 (ToJSON, FromJSON)
import qualified Data.Set                   as Set
import           GHC.Generics               (Generic)
import           Language.Plutus.Lift       (LiftPlc (..), TypeablePlc (..))
import           Language.Plutus.Runtime    (Height, PendingTx (..), PendingTxOut (..), PendingTxOutType (..),
                                             PubKey (..), ValidatorHash, Value)
import qualified Language.Plutus.Runtime.TH as TH
import           Language.Plutus.TH         (plutus)
import qualified Language.Plutus.TH         as Builtins
import           Prelude                    hiding ((&&))
import           Wallet.API                 (WalletAPI (..), WalletAPIError, otherError, signAndSubmit)
import           Wallet.UTXO                (DataScript (..), TxOutRef', Validator (..), scriptTxIn, scriptTxOut)
import qualified Wallet.UTXO                as UTXO
import qualified Wallet.UTXO.Runtime        as Runtime
import           Playground.Contract

-- | Tranche of a vesting scheme.
data VestingTranche = VestingTranche {
    vestingTrancheDate   :: Height,
    vestingTrancheAmount :: Value
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

instance LiftPlc VestingTranche
instance TypeablePlc VestingTranche

-- | A vesting scheme consisting of two tranches. Each tranche defines a date
--   (block height) after which an additional amount of money can be spent.
data Vesting = Vesting {
    vestingTranche1 :: VestingTranche,
    vestingTranche2 :: VestingTranche,
    vestingOwner    :: PubKey
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

instance LiftPlc Vesting
instance TypeablePlc Vesting

-- | The total amount of money vested
totalAmount :: Vesting -> Value
totalAmount Vesting{..} =
    vestingTrancheAmount vestingTranche1 + vestingTrancheAmount vestingTranche2

-- | Data script for vesting utxo
data VestingData = VestingData {
    vestingDataHash    :: ValidatorHash, -- ^ Hash of the validator script
    vestingDataPaidOut :: Value -- ^ How much of the vested value has already been retrieved
    } deriving (Eq, Generic)

instance LiftPlc VestingData
instance TypeablePlc VestingData

-- | Lock some funds with the vesting validator script and return a
--   [[VestingData]] representing the current state of the process
vestFunds :: (
    MonadError WalletAPIError m,
    WalletAPI m)
    => Vesting
    -> Value
    -> String
    -> m VestingData
vestFunds vst value unused = do
    _ <- if value < totalAmount vst then otherError "Value must not be smaller than vested amount" else pure ()
    let v' = UTXO.Value $ fromIntegral value
    (payment, change) <- createPaymentWithChange v'
    let vs = validatorScript vst
        o = scriptTxOut v' vs (DataScript $ UTXO.lifted vd)
        vd =  VestingData (validatorScriptHash vst) 0
    signAndSubmit payment [o, change]
    pure vd

-- | Retrieve some of the vested funds.
retrieveFunds :: (
    Monad m,
    WalletAPI m)
    => Vesting
    -> VestingData -- ^ Value that has already been taken out
    -> TxOutRef'  -- ^ Transaction output locked by the vesting validator script
    -> UTXO.Value -- ^ Value we want to take out now
    -> m VestingData
retrieveFunds vs vd r vnow = do
    oo <- payToPublicKey vnow
    let val = validatorScript vs
        o   = scriptTxOut remaining val (DataScript $ UTXO.lifted vd')
        remaining = (fromIntegral $ totalAmount vs) - vnow
        vd' = vd {vestingDataPaidOut = fromIntegral vnow + vestingDataPaidOut vd }
        inp = scriptTxIn r val UTXO.unitRedeemer
    signAndSubmit (Set.singleton inp) [oo, o]
    pure vd'

validatorScriptHash :: Vesting -> ValidatorHash
validatorScriptHash = Runtime.plcValidatorHash . validatorScript

validatorScript :: Vesting -> Validator
validatorScript v = Validator val where
    val = UTXO.applyScript inner (UTXO.lifted v)
    inner = UTXO.fromPlcCode $(plutus [| \Vesting{..} () VestingData{..} (p :: PendingTx ValidatorHash) ->
        let

            eqBs :: ValidatorHash -> ValidatorHash -> Bool
            eqBs = $(TH.eqValidator)

            eqPk :: PubKey -> PubKey -> Bool
            eqPk = $(TH.eqPubKey)

            infixr 3 &&
            (&&) :: Bool -> Bool -> Bool
            (&&) = $( TH.and )

            PendingTx _ os _ _ h _ _ = p
            VestingTranche d1 a1 = vestingTranche1
            VestingTranche d2 a2 = vestingTranche2

            -- We assume here that the txn outputs are always given in the same
            -- order (1 PubKey output, followed by 0 or 1 script outputs)
            amountSpent :: Value
            amountSpent = case os of
                ((PendingTxOut v' _ (PubKeyTxOut pk))::PendingTxOut):(_::[PendingTxOut])
                    | pk `eqPk` vestingOwner -> v'
                (_::[PendingTxOut]) -> Builtins.error ()

            -- Value that has been released so far under the scheme
            currentThreshold =
                if h >= d1
                then if h >= d2
                    -- everything can be spent
                     then a1 + a2
                     -- only the first tranche can be spent (we are between d1 and d2)
                     else a1
                -- Nothing has been released yet
                else 0

            newAmount = vestingDataPaidOut + amountSpent

            -- Verify that the amount taken out, plus the amount already taken
            -- out before, does not exceed the threshold that is currently
            -- allowed
            amountsValid = newAmount <= currentThreshold

            -- Check that the remaining output is locked by the same validation
            -- script
            txnOutputsValid = case os of
                (_::PendingTxOut):(PendingTxOut _ (Just (vl', _))  DataTxOut::PendingTxOut):(_::[PendingTxOut]) ->
                    vl' `eqBs` vestingDataHash
                (_::[PendingTxOut]) -> Builtins.error ()

            isValid = amountsValid && txnOutputsValid
        in
        if isValid then () else Builtins.error () |])

$(mkFunction 'vestFunds)
"""

evaluation :: Evaluation
evaluation =
  { balances: [
      { name: "charles"
      , value: 600.0
      },
      { name: "kris"
      , value: 10.0
      },
      { name: "david"
      , value: 15.0
      },
      { name: "manuel"
      , value: 123.0
      }
    ]
  , transfers: [
      { source: "charles"
      , target: "kris"
      , value: 10.0
      },
      { source: "charles"
      , target: "david"
      , value: 10.0
      },
      { source: "charles"
      , target: "manuel"
      , value: 20.0
      },
      { source: "manuel"
      , target: "kris"
      , value: 5.0
      },
      { source: "manuel"
      , target: "david"
      , value: 5.0
      }
    ]
  }


compilationResult :: CompilationResult
compilationResult = Right [FunctionSchema {argumentSchema: [SimpleObjectArgument [Tuple "vestingTranche1" (SimpleObjectArgument [Tuple "vestingTrancheDate" SimpleIntArgument, Tuple "vestingTrancheAmount" SimpleIntArgument]), Tuple "vestingTranche2" (SimpleObjectArgument [Tuple "vestingTrancheDate" SimpleIntArgument, Tuple "vestingTrancheAmount" SimpleIntArgument]), Tuple "vestingOwner" (SimpleObjectArgument [Tuple "getPubKey" SimpleIntArgument])], SimpleIntArgument, SimpleStringArgument], functionName: Fn "vestFunds"}]


actions :: Array Action
actions = [{walletId: WalletId "kris0001", functionSchema: FunctionSchema {argumentSchema: [SimpleObjectArgument [Tuple "vestingTranche1" (SimpleObjectArgument [Tuple "vestingTrancheDate" SimpleIntArgument, Tuple "vestingTrancheAmount" SimpleIntArgument]), Tuple "vestingTranche2" (SimpleObjectArgument [Tuple "vestingTrancheDate" SimpleIntArgument, Tuple "vestingTrancheAmount" SimpleIntArgument]), Tuple "vestingOwner" (SimpleObjectArgument [Tuple "getPubKey" SimpleIntArgument])], SimpleIntArgument, SimpleStringArgument], functionName: Fn "vestFunds"}},{walletId: WalletId "david0001", functionSchema: FunctionSchema {argumentSchema: [SimpleObjectArgument [Tuple "vestingTranche1" (SimpleObjectArgument [Tuple "vestingTrancheDate" SimpleIntArgument, Tuple "vestingTrancheAmount" SimpleIntArgument]), Tuple "vestingTranche2" (SimpleObjectArgument [Tuple "vestingTrancheDate" SimpleIntArgument, Tuple "vestingTrancheAmount" SimpleIntArgument]), Tuple "vestingOwner" (SimpleObjectArgument [Tuple "getPubKey" SimpleIntArgument])], SimpleIntArgument, SimpleStringArgument], functionName: Fn "vestFunds"}}]