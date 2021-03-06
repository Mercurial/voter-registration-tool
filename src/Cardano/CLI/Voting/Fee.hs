-- | Tools used to estimate the fee associated with a vote transaction
-- and ensure that the unspent value of the TxIns are enough to cover
-- the fee associated with submitting the transaction.
--
-- I use two heuristics to calculate this:
--   1. A base fee estimate, calculated by estimating the fee of a
--      vote transaction with no TxIns.
--   2. A per-txin fee estimate. If the first UTxO we find cannot
--      cover the cost of the fee, we need to find additional UTxOs.
--      Each of these UTxOs forms a TxIn which provides funds for our
--      vote transaction. Increasing the number of TxIns in a
--      transaction increases the fee associated with that
--      transaction. In the pathological case, each extra TxIn may
--      introduce more fees than funds. We use the per-txin fee
--      estimate to ensure we fail appropriately in this case.
--
-- These two parameters are encoded in the "FeeParams" type.

module Cardano.CLI.Voting.Fee where

import           Data.String (fromString)

import           Cardano.API (Address, AsType (AsPaymentKey, AsStakeKey), Key, LocalNodeConnectInfo,
                     Lovelace (Lovelace), NetworkId, PaymentCredential, PaymentKey, SigningKey,
                     StakeAddressReference, StakeCredential, StakeKey, TTL, Tx, TxBody,
                     TxIn (TxIn), TxMetadata, VerificationKey, estimateTransactionFee,
                     getVerificationKey, localNodeNetworkId, makeShelleyAddress,
                     makeShelleyKeyWitness, makeShelleyTransaction, makeSignedTransaction,
                     makeTransactionMetadata, serialiseToRawBytes, serialiseToRawBytesHex,
                     txExtraContentEmpty, verificationKeyHash)
import           Cardano.Api.Typed (PaymentCredential (PaymentCredentialByKey), Shelley,
                     ShelleyWitnessSigningKey (WitnessPaymentKey),
                     StakeAddressReference (StakeAddressByValue),
                     StakeCredential (StakeCredentialByKey), StandardShelley, TxId (TxId),
                     TxIx (TxIx), TxMetadataValue (TxMetaBytes, TxMetaMap, TxMetaText),
                     TxOut (TxOut), deterministicSigningKey, deterministicSigningKeySeedSize,
                     txCertificates, txMetadata, txUpdateProposal, txWithdrawals)
import           Cardano.Api.Typed (Shelley, StandardShelley)
import qualified Cardano.Binary as CBOR
import qualified Cardano.Crypto.Hash.Class as Crypto
import qualified Cardano.Crypto.Seed as Crypto
import           Shelley.Spec.Ledger.PParams (PParams)
import qualified Shelley.Spec.Ledger.PParams as Shelley

-- | Fee characteristics of a transaction
data FeeParams = FeeParams
    { feeBase    :: Lovelace
    -- ^ The fee of a vote transaction with no TxIns
    , feePerTxIn :: Lovelace
    -- ^ The increase in fees for adding a TxIn
    }

-- | Transactions that aren't fully spent.
type UnspentSources
  = [( TxIn
     -- ^ Transaction in
     , Lovelace
     -- ^ Unspent amount
     )]

-- | Total amount of unspent value.
unspentValue :: UnspentSources -> Lovelace
unspentValue =
  foldr
    (\(_, Lovelace unspent) (Lovelace acc) -> Lovelace $ acc + unspent)
    (Lovelace 0)

-- | All transactions that aren't fully spent.
unspentSources :: UnspentSources -> [TxIn]
unspentSources = foldr (\(txin, _) -> (txin:)) mempty

-- | Estimate the fee required for a vote transaction.
estimateVoteTxFee
  :: NetworkId
  -> PParams StandardShelley
  -> TTL
  -> [TxIn]
  -> Address Shelley
  -> Lovelace
  -> TxMetadata
  -> Lovelace
estimateVoteTxFee networkId pparams ttl txins addr txBaseValue meta =
  let
    txoutsNoFee = [TxOut addr txBaseValue]
    txBody = makeShelleyTransaction
               txExtraContentEmpty {
                 txCertificates   = [],
                 txWithdrawals    = [],
                 txMetadata       = Just meta,
                 txUpdateProposal = Nothing
               }
               ttl
               (toEnum 0)
               txins
               txoutsNoFee
    tx = makeSignedTransaction [] txBody
  in
    estimateTransactionFee
      networkId
      (Shelley._minfeeB pparams)
      (Shelley._minfeeA pparams)
      tx
      (length txins)
      (length txoutsNoFee)
      1
      0

-- | Estimate the fee characteristics of a vote transaction. The base
-- fee, and the how the fee changes as we add more transaction inputs.
estimateVoteFeeParams
  :: NetworkId
  -> PParams StandardShelley
  -> TxMetadata
  -> FeeParams
estimateVoteFeeParams networkId pparams meta =
  let
    mockTTL :: TTL
    mockTTL = 1

    mockSkey :: Key keyrole => AsType keyrole -> SigningKey keyrole
    mockSkey keyrole = deterministicSigningKey keyrole (Crypto.mkSeedFromBytes (fromString $ replicate (fromInteger $ toInteger $ deterministicSigningKeySeedSize keyrole) 'x'))

    mockVkey :: VerificationKey PaymentKey
    mockVkey = getVerificationKey (mockSkey AsPaymentKey)

    mockPaymentCredential :: PaymentCredential
    mockPaymentCredential = PaymentCredentialByKey $ verificationKeyHash mockVkey

    mockVkeyStake :: VerificationKey StakeKey
    mockVkeyStake = getVerificationKey (mockSkey AsStakeKey)

    mockStakeCredential :: StakeCredential
    mockStakeCredential = StakeCredentialByKey $ verificationKeyHash mockVkeyStake

    mockStakeAddressRef :: StakeAddressReference
    mockStakeAddressRef = StakeAddressByValue mockStakeCredential

    mockAddr :: Address Shelley
    mockAddr = makeShelleyAddress networkId mockPaymentCredential mockStakeAddressRef

    -- Start with a base estimate
    (Lovelace feeBase)    = estimateVoteTxFee networkId pparams mockTTL [] mockAddr (Lovelace 0) meta
    -- Estimate the fee per extra txin
    mockTxIn   = TxIn (TxId $ Crypto.hashWith CBOR.serialize' ()) (TxIx 1)
    (Lovelace feeWithMockTxIn) = estimateVoteTxFee networkId pparams mockTTL [mockTxIn] mockAddr (Lovelace 0) meta
    feePerTxIn = Lovelace $ feeWithMockTxIn - feeBase
  in
    FeeParams (Lovelace feeBase) feePerTxIn

findUnspent
  :: FeeParams
  -- ^ Estimates for the base fee and the fee per TxIn
  -> UnspentSources
  -- ^ UTxOs we can use to cover fees
  -> Maybe UnspentSources
  -- ^ Nothing if given UTxOs cannot cover fees. Otherwise, UTxOs
  -- actually used to cover fees.
findUnspent feeParams utxos =
  case takeUntilFeePaid feeParams utxos of
    [] -> Nothing
    xs -> Just xs

takeUntilFeePaid :: FeeParams -> [(a , Lovelace)] -> [(a , Lovelace)]
takeUntilFeePaid (FeeParams feeBase (Lovelace feePerTxIn)) =
  let
    initialFeeTarget = feeBase
  in
    go initialFeeTarget (Lovelace 0)

  where
    go :: Lovelace -> Lovelace -> [(a, Lovelace)] -> [(a, Lovelace)]
    go (Lovelace target) (Lovelace acc) xs
      | acc >= target = xs
    go target _ []
      = []
    go (Lovelace target) (Lovelace acc) ((a, Lovelace unspent):xs)
      =
      let
        newTarget = Lovelace $ target + feePerTxIn
        newAcc    = Lovelace $ acc + unspent
        txs       = go newTarget newAcc xs
      in
        (a, Lovelace unspent):txs
