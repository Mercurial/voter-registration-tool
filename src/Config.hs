{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module Config (Config(Config), opts, mkConfig) where

import Data.Text (Text)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Except (MonadError, ExceptT, throwError, catchError)
import Control.Lens ((#))
import Control.Lens.TH

import Options.Applicative

import Cardano.CLI.Environment ( EnvSocketError, readEnvSocketPath)
import qualified Cardano.API as Api
import Cardano.API (Address, SigningKey, StakeKey, Witness, NetworkId, FileError, PaymentKey, Bech32DecodeError)
import Cardano.Api.Typed (Shelley)
import Cardano.CLI.Shelley.Key (InputDecodeError)
import Cardano.CLI.Shelley.Commands (WitnessFile(WitnessFile))
import Cardano.CLI.Types (SigningKeyFile (..), SocketPath)
import Cardano.Api.TextView (TextViewError)

import Extern 
import CLI.Interop (stripTrailingNewlines)

import Cardano.API.Voting (VotingKeyPublic, deserialiseFromBech32)

data Config
  = Config { cfgPaymentAddress    :: Address Shelley
           , cfgStakeSigningKey   :: SigningKey StakeKey
           , cfgPaymentSigningKey :: SigningKey PaymentKey
           , cfgVotePublicKey     :: VotingKeyPublic
           , cfgNetworkId         :: NetworkId
           }
  deriving (Show)

data FileErrors = FileErrorInputDecode InputDecodeError
                | FileErrorTextView TextViewError
  deriving (Show)

makePrisms ''FileErrors

instance AsInputDecodeError FileErrors where
  _InputDecodeError = _FileErrorInputDecode

instance AsTextViewError FileErrors where
  _TextViewError = _FileErrorTextView

data ConfigError
  = ConfigFailedToReadFile (Api.FileError FileErrors)
  | ConfigNotAStakeSigningKey NotStakeSigningKeyError
  | ConfigNotAPaymentSigningKey NotPaymentSigningKeyError
  | ConfigFailedToDecodeBech32 Bech32DecodeError
  deriving (Show)

makePrisms ''ConfigError

instance AsFileError ConfigError FileErrors where
  __FileError = _ConfigFailedToReadFile

instance AsNotStakeSigningKeyError ConfigError where
  _NotStakeSigningKeyError = _ConfigNotAStakeSigningKey

instance AsNotPaymentSigningKeyError ConfigError where
  _NotPaymentSigningKeyError = _ConfigNotAPaymentSigningKey

instance AsBech32DecodeError ConfigError where
  _Bech32DecodeError = _ConfigFailedToDecodeBech32
  
mkConfig
  :: Opts
  -> ExceptT ConfigError IO Config
mkConfig (Opts stateDir pskf addr vpkf sskf networkId) = do
  stkSign <- readStakeSigningKey (SigningKeyFile sskf)
  votepk  <- readVotePublicKey vpkf
  paySign <- readPaymentSigningKey (SigningKeyFile pskf)

  pure $ Config addr stkSign paySign votepk networkId

data Opts
  = Opts { optStateDir              :: FilePath
         , optPaymentSigningKeyFile :: FilePath
         , optPaymentAddress        :: Address Shelley
         , optVotePublicKeyFile     :: FilePath
         , optStakeSigningKeyFile   :: FilePath
         , optNetworkId             :: NetworkId
         }
  deriving (Eq, Show)

parseOpts :: Parser Opts
parseOpts = Opts
  <$> strOption (long "state-dir" <> metavar "DIR" <> help "state directory" <> showDefault <> value "./state-node-testnet")
  <*> strOption (long "payment-signing-key" <> metavar "FILE" <> help "file used to sign transaction")
  <*> option (readerFromAttoParser parseAddress) (long "payment-address" <> metavar "STRING" <> help "address associated with payment (hard-coded to use info from first utxo of address)")
  <*> strOption (long "vote-public-key" <> metavar "FILE" <> help "vote key generated by jcli (corresponding private key must be ed25519extended)")
  <*> strOption (long "stake-signing-key" <> metavar "FILE" <> help "stake authorizing vote key")
  <*> pNetworkId

opts =
  info
    ( parseOpts <**> helper )
    ( fullDesc
    <> progDesc "Create a vote transaction"
    <> header "voter-registration - a tool to create vote transactions"
    )
