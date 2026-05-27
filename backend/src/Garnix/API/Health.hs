module Garnix.API.Health where

import Garnix.DB qualified as DB
import Garnix.Duration
import Garnix.Monad
import Garnix.Prelude

data HealthAPI route = HealthAPI
  { _healthAPIHealth :: route :- "check" :> Get '[JSON] (),
    _healthAPITriggerCritical :: route :- "some-hard-to-guess-endpoint-ieTh5bi1" :> Get '[JSON] (),
    _healthAPISlowAnswer :: route :- "slow-answer-umuS9ain" :> Get '[JSON] ()
  }
  deriving (Generic)

healthAPI :: HealthAPI (AsServerT M)
healthAPI =
  HealthAPI
    { _healthAPIHealth = healthCheck,
      _healthAPITriggerCritical = log Critical "critical test message",
      _healthAPISlowAnswer = do
        liftIO $ threadDelay (fromSeconds @Int 4)
        pure ()
    }

healthCheck :: M ()
healthCheck = DB.checkHealth
