import Config

# Shared deployments require OPTIMAL_AUTH_REQUIRED=true or an explicit
# auth_required: true setting. runtime.exs accepts only literal true/false
# environment values and otherwise preserves the configured setting.
# MIX_ENV=prod alone does not change the trusted-local default.
