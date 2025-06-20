defmodule ThirdpartyWeb.Presence do
  use Phoenix.Presence,
    otp_app: :thirdparty,
    pubsub_server: Thirdparty.PubSub
end
