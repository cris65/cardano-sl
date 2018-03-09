{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE QuasiQuotes          #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns         #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Cardano.Wallet.API.V1.Swagger where

import           Universum

import           Cardano.Wallet.API.Request.Filter
import           Cardano.Wallet.API.Request.Pagination
import           Cardano.Wallet.API.Request.Sort
import           Cardano.Wallet.API.Response
import           Cardano.Wallet.API.Types
import qualified Cardano.Wallet.API.V1.Errors as Errors
import           Cardano.Wallet.API.V1.Generic (gconsName)
import           Cardano.Wallet.API.V1.Parameters
import           Cardano.Wallet.API.V1.Swagger.Example
import           Cardano.Wallet.API.V1.Types
import           Cardano.Wallet.TypeLits (KnownSymbols (..))
import qualified Pos.Core as Core
import           Pos.Core.Update (SoftwareVersion)
import           Pos.Util.CompileInfo (CompileTimeInfo, ctiGitRevision)
import           Pos.Wallet.Web.Swagger.Instances.Schema ()

import           Control.Lens ((?~))
import           Data.Aeson (ToJSON (..), encode)
import           Data.Aeson.Encode.Pretty
import qualified Data.ByteString.Lazy as BL
import           Data.Map (Map)
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import           Data.String.Conv
import           Data.Swagger hiding (Example, Header, example)
import           Data.Swagger.Declare
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import           Data.Typeable
import           NeatInterpolation
import           Servant (ServantErr (..))
import           Servant.API.Sub
import           Servant.Swagger
import           Test.QuickCheck
import           Test.QuickCheck.Gen
import           Test.QuickCheck.Random

--
-- Helper functions
--

-- | Generates an example for type `a` with a static seed.
genExample :: (ToJSON a, Example a) => a
genExample = (unGen (resize 3 example)) (mkQCGen 42) 42

-- | Generates a `NamedSchema` exploiting the `ToJSON` instance in scope,
-- by calling `sketchSchema` under the hood.
fromExampleJSON :: (ToJSON a, Typeable a, Example a)
                  => proxy a
                  -> Declare (Definitions Schema) NamedSchema
fromExampleJSON (_ :: proxy a) = do
    let (randomSample :: a) = genExample
    return $ NamedSchema (Just $ fromString $ show $ typeOf randomSample) (sketchSchema randomSample)


-- | Surround a Text with another
surroundedBy :: Text -> Text -> Text
surroundedBy wrap context = wrap <> context <> wrap

--
-- Instances
--

instance HasSwagger (apiType a :> res) =>
         HasSwagger (WithDefaultApiArg apiType a :> res) where
    toSwagger _ = toSwagger (Proxy @(apiType a :> res))

instance HasSwagger (argA a :> argB a :> res) =>
         HasSwagger (AlternativeApiArg argA argB a :> res) where
    toSwagger _ = toSwagger (Proxy @(argA a :> argB a :> res))

instance (KnownSymbols tags, HasSwagger subApi) => HasSwagger (Tags tags :> subApi) where
    toSwagger _ =
        let newTags    = map toS (symbolVals (Proxy @tags))
            swgr       = toSwagger (Proxy @subApi)
        in swgr & over (operationsOf swgr . tags) (mappend (Set.fromList newTags))

instance (Typeable res, KnownSymbols syms, HasSwagger subApi) => HasSwagger (FilterBy syms res :> subApi) where
    toSwagger _ =
        let swgr       = toSwagger (Proxy @subApi)
            allOps     = map toText $ symbolVals (Proxy @syms)
        in swgr & over (operationsOf swgr . parameters) (addFilterOperations allOps)
          where
            addFilterOperations :: [Text] -> [Referenced Param] -> [Referenced Param]
            addFilterOperations ops xs = map (Inline . newParam) ops <> xs

            newParam :: Text -> Param
            newParam opName =
                let typeOfRes = fromString $ show $ typeRep (Proxy @ res)
                in Param {
                  _paramName = opName
                , _paramRequired = Nothing
                , _paramDescription = Just $ "A **FILTER** operation on a " <> typeOfRes <> "."
                , _paramSchema = ParamOther ParamOtherSchema {
                         _paramOtherSchemaIn = ParamQuery
                       , _paramOtherSchemaAllowEmptyValue = Nothing
                       , _paramOtherSchemaParamSchema = mempty
                       }
                }

instance (Typeable res, KnownSymbols syms, HasSwagger subApi) => HasSwagger (SortBy syms res :> subApi) where
    toSwagger _ =
        let swgr       = toSwagger (Proxy @subApi)
        in swgr & over (operationsOf swgr . parameters) addSortOperation
          where
            addSortOperation :: [Referenced Param] -> [Referenced Param]
            addSortOperation xs = (Inline newParam) : xs

            newParam :: Param
            newParam =
                let typeOfRes = fromString $ show $ typeRep (Proxy @ res)
                    allowedKeys = T.intercalate "," (map toText $ symbolVals (Proxy @syms))
                in Param {
                  _paramName = "sort_by"
                , _paramRequired = Just False
                , _paramDescription = Just (sortDescription typeOfRes allowedKeys)
                , _paramSchema = ParamOther ParamOtherSchema {
                         _paramOtherSchemaIn = ParamQuery
                       , _paramOtherSchemaAllowEmptyValue = Just True
                       , _paramOtherSchemaParamSchema = mempty
                       }
                }

instance (HasSwagger subApi) => HasSwagger (WalletRequestParams :> subApi) where
    toSwagger _ =
        let swgr       = toSwagger (Proxy @(WithWalletRequestParams subApi))
        in swgr & over (operationsOf swgr . parameters) (map toDescription)
          where
            toDescription :: Referenced Param -> Referenced Param
            toDescription (Inline p@(_paramName -> pName)) =
                case M.lookup pName requestParameterToDescription of
                    Nothing -> Inline p
                    Just d  -> Inline (p & description .~ Just d)
            toDescription x = x

instance ToParamSchema WalletId

instance ToSchema Core.Address where
    declareNamedSchema = pure . paramSchemaToNamedSchema defaultSchemaOptions

instance ToParamSchema Core.Address where
  toParamSchema _ = mempty
    & type_ .~ SwaggerString

instance ToParamSchema (V1 Core.Address) where
  toParamSchema _ = toParamSchema (Proxy @Core.Address)


--
-- Descriptions
--

requestParameterToDescription :: Map T.Text T.Text
requestParameterToDescription = M.fromList [
    ("page", pageDescription)
  , ("per_page", perPageDescription (fromString $ show maxPerPageEntries) (fromString $ show defaultPerPageEntries))
  ]

pageDescription :: T.Text
pageDescription = [text|
The page number to fetch for this request. The minimum is **1**.
If nothing is specified, **this value defaults to 1** and always shows the first
entries in the requested collection.
|]

perPageDescription :: T.Text -> T.Text -> T.Text
perPageDescription maxValue defaultValue = [text|
The number of entries to display for each page. The minimum is **1**, whereas the maximum
is **$maxValue**. If nothing is specified, **this value defaults to $defaultValue**.
|]

sortDescription :: Text -> Text -> Text
sortDescription resource allowedKeys = [text|
A **SORT** operation on this $resource. Allowed keys: `$allowedKeys`.
|]


errorsDescription :: Text
errorsDescription = [text|
Error Name | HTTP Error code | Example
-----------|-----------------|---------
$errors
|] where
  errors = T.intercalate "\n" rows
  rows = map mkRow Errors.sample
  mkRow err = T.intercalate "|"
    [ surroundedBy "`" (gconsName err)
    , T.pack $ show $ errHTTPCode $ Errors.toServantError err
    , T.decodeUtf8 $ BL.toStrict $ encode err
    ]

highLevelDescription :: DescriptionEnvironment -> T.Text
highLevelDescription DescriptionEnvironment{..} = [text|
This is the specification for the Cardano Wallet API, automatically generated as a [Swagger](https://swagger.io/)
spec from the [Servant](http://haskell-servant.readthedocs.io/en/stable/) API of [Cardano](https://github.com/input-output-hk/cardano-sl).

Software Version | Git Revision
-----------------|-------------------
$deGitRevision   | $deSoftwareVersion

## Getting Started

In the following examples, we will use *curl* to illustrate request to an API running on the
default port **8090**.

> Please note that wallet web API uses TLS for secure communication. Requests to the API need
to send a client CA certificate that was used when launching the node and identifies the client as
being permitted to invoke the server API.

### Creating a New Wallet

You can create your first wallet using the `POST /api/v1/wallets` endpoint as follow:

```
curl -X POST https://localhost:8090/api/v1/wallets                     \
     -H "Content-Type: application/json; charset=utf-8"                \
     -H "Accept: application/json; charset=utf-8"                      \
     --cacert ./scripts/tls-files/ca.crt                               \
     -d '{                                                             \
  "operation": "create",                                               \
  "backupPhrase": ["squirrel", "material", "silly", "twice", "direct", \
    "slush", "pistol", "razor", "become", "junk", "kingdom", "flee"],  \
  "assuranceLevel": "normal",                                          \
  "name": "MyFirstWallet"                                              \
}'
```

As a response, the API provides you with a wallet `id` used in subsequent requests to uniquely
identity the wallet. Make sure to store it / write it down.

```json
{
    "status": "success",
    "data": {
        "id": "Ae2tdPwUPE...8V3AVTnqGZ",
        "name": "MyFirstWallet",
        "balance": 0
    },
    "meta": {
        "pagination": {
            "totalPages": 1,
            "page": 1,
            "perPage": 1,
            "totalEntries": 1
        }
    }
}
```

You have just created your first wallet. Information about this wallet can be retrieved using
the `GET /api/v1/wallets/{walletId}` endpoint as follow:

```
curl -X GET https://localhost:8090/api/v1/wallets/{{walletId}} \
     -H "Accept: application/json; charset=utf-8"              \
     --cacert ./scripts/tls-files/ca.crt                       \
```

### Receiving Money

To receive money from other user you should provide your address. This address can be obtained
from an account. Each wallet contains at least one account, you can think of account as a
pocket inside of your wallet. Besides, you can view all existing accounts of a wallet by using
the `GET /api/v1/wallets/{{walletId}}/accounts` endpoint as follow:

```
curl -X GET https://localhost:8090/api/v1/wallets/{{walletId}}/accounts?page=1&per_page=10 \
     -H "Accept: application/json; charset=utf-8"                                          \
     --cacert ./scripts/tls-files/ca.crt                                                   \
```

Since you have, for now, only a single wallet, you'll see something like this:

```json
{
    "status": "success",
    "data": [
        {
            "index": 2147483648,
            "addresses": [
                "DdzFFzCqrh...fXSru1pdFE"
            ],
            "amount": 0,
            "name": "Initial account",
            "walletId": "Ae2tdPwUPE...8V3AVTnqGZ"
        }
    ],
    "meta": {
        "pagination": {
            "totalPages": 1,
            "page": 1,
            "perPage": 10,
            "totalEntries": 1
        }
    }
}
```

Each account has at least one address, all listed under the `addresses` field. You can
communicate one of these addresses to receive money on the associated account.


### Sending Money

In order to send money from one of your account to another address, you can create a new
payment transaction using the `POST /api/v1/transactions` endpoint as follow:

```
curl -X POST https://localhost:8090/api/v1/transactions \
     -H "Content-Type: application/json; charset=utf-8" \
     -H "Accept: application/json; charset=utf-8"       \
     --cacert ./scripts/tls-files/ca.crt                \
     -d '{                                              \
  "destinations": [{                                    \
    "amount": 14,                                       \
    "address": "A7k5bz1QR2...Tx561NNmfF"                \
  }],                                                   \
  "source": {                                           \
    "accountIndex": 0,                                  \
    "walletId": "Ae2tdPwUPE...8V3AVTnqGZ"               \
  }                                                     \
}'
```

Note that, in order to perform a transaction, you need to have some existing coins on the
source account! When the transaction succeeds, funds are _moved_ from an address to another.
Note that, you can at any time see the status of your wallets by using the
`GET /api/v1/transactions/{{walletId}}` endpoint as follow:

```
curl -X GET https://localhost:8090/api/v1/wallets/{{walletId}}?account_index=0  \
     -H "Accept: application/json; charset=utf-8"                               \
     --cacert ./scripts/tls-files/ca.crt                                        \
```

We have here constrainted the request to a specific account, with our previous transaction the
output should look roughly similar to this:

```json
{
    "status": "success",
    "data": [
        {
            "amount": 14,
            "inputs": [{
              "amount": 14,
              "address": "DdzFFzCqrh...fXSru1pdFE"
            }],
            "direction": "outgoing",
            "outputs": [{
              "amount": 14,
              "address": "A7k5bz1QR2...Tx561NNmfF"
            }],
            "confirmations": 42,
            "id": "43zkUzCVi7...TT31uDfEF7",
            "type": "local"
        }
    ],
    "meta": {
        "pagination": {
            "totalPages": 1,
            "page": 1,
            "perPage": 10,
            "totalEntries": 1
        }
    }
}
```

## Pagination

**All GET requests of the API are paginated by default**. Whilst this can be a source of surprise, is
the best way of ensuring the performance of GET requests is not affected by the size of the data storage.

Version `V1` introduced a different way of requesting information to the API. In particular, GET requests
which returns a _collection_ (i.e. typically a JSON array of resources) lists extra parameters which can be
used to modify the shape of the response. In particular, those are:

* `page`: (Default value: **1**).
* `per_page`: (Default value: **$deDefaultPerPage**)

For a more accurate description, see the section `Parameters` of each GET request, but as a
brief overview the first two control how many results and which results to access in a
paginated request.


## Filtering and sorting

`GET` endpoints which list collection of resources supports filters & sort operations, which are clearly marked
in the swagger docs with the `FILTER` or `SORT` labels. The query format is quite simple, and it goes this way:

### Filter operators

| Operator | Description                                                               | Example                |
|----------|---------------------------------------------------------------------------|------------------------|
| -        | If **no operator** is passed, this is equivalent to `EQ` (see below).     | `balance=10`           |
| `EQ`     | Retrieves the resources with index _equal_ to the one provided.           | `balance=EQ[10]`       |
| `LT`     | Retrieves the resources with index _less than_ the one provided.          | `balance=LT[10]`       |
| `LTE`    | Retrieves the resources with index _less than equal_ the one provided.    | `balance=LTE[10]`      |
| `GT`     | Retrieves the resources with index _greater than_ the one provided.       | `balance=GT[10]`       |
| `GTE`    | Retrieves the resources with index _greater than equal_ the one provided. | `balance=GTE[10]`      |
| `RANGE`  | Retrieves the resources with index _within the inclusive range_ [k,k].    | `balance=RANGE[10,20]` |

### Sort operators

| Operator | Description                                                               | Example                |
|----------|---------------------------------------------------------------------------|------------------------|
| `ASC`    | Sorts the resources with the given index in _ascending_ order.            | `sort_by=ASC[balance]` |
| `DES`    | Sorts the resources with the given index in _descending_ order.           | `sort_by=DES[balance]` |
| -        | If **no operator** is passed, this is equivalent to `DES` (see above).    | `sort_by=balance`      |


## Errors

In case a request cannot be served by the API, a non-2xx HTTP response will be issue, together with a
[JSend-compliant](https://labs.omniti.com/labs/jsend) JSON Object describing the error in detail together
with a numeric error code which can be used by API consumers to implement proper error handling in their
application. For example, here's a typical error which might be issued:

``` json
$deErrorExample
```

### Existing wallet errors

$deWalletErrorTable


## Mnemonic Codes

The full list of accepted mnemonic codes to secure a wallet is defined by the BIP-39
specifications and available [here](https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt).


## Versioning & Legacy

The API is **versioned**, meaning that is possible to access different versions of the API by
adding the _version number_ in the URL.

**For the sake of backward compatibility, we expose the legacy version of the API, available
simply as unversioned endpoints.**

This means that _omitting_ the version number would call the old version of the API. Deprecated
endpoints are currently grouped under an appropriate section; they would be removed in upcoming
released, if you're starting a new integration with Cardano-SL, please ignore these.

Note that Compatibility between major versions is not _guaranteed_, i.e. the request & response
formats might differ.
|]


--
-- The API
--

data DescriptionEnvironment = DescriptionEnvironment
  { deErrorExample          :: !T.Text
  , deDefaultPerPage        :: !T.Text
  , deWalletResponseExample :: !T.Text
  , deWalletErrorTable      :: !T.Text
  , deGitRevision           :: !T.Text
  , deSoftwareVersion       :: !T.Text
  }

api :: HasSwagger a
    => (CompileTimeInfo, SoftwareVersion)
    -> Proxy a
    -> Swagger
api (compileInfo, curSoftwareVersion) walletAPI = toSwagger walletAPI
  & info.title   .~ "Cardano Wallet API"
  & info.version .~ "2.0"
  & host ?~ "127.0.0.1:8090"
  & info.description ?~ (highLevelDescription $ DescriptionEnvironment
    { deErrorExample          = toS $ encodePretty Errors.WalletNotFound
    , deDefaultPerPage        = fromString (show defaultPerPageEntries)
    , deWalletResponseExample = toS $ encodePretty (genExample @(WalletResponse [Account]))
    , deWalletErrorTable      = errorsDescription
    , deGitRevision           = ctiGitRevision compileInfo
    , deSoftwareVersion       = fromString $ show curSoftwareVersion
    })
  & info.license ?~ ("MIT" & url ?~ URL "http://mit.com")
