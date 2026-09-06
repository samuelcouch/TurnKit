# frozen_string_literal: true

module TurnKit
  # Application-owned authorization boundary. A configured policy must return
  # true explicitly; the model never supplies the principal.
  module Authorization
    module_function

    def authorize!(action, principal:, **resource)
      policy = TurnKit.authorization_policy
      return true unless policy
      allowed = policy.respond_to?(:authorize?) ? policy.authorize?(action, principal: principal, **resource) : policy.call(action, principal: principal, **resource)
      raise AuthorizationError, "not authorized to #{action}" unless allowed == true
      true
    end
  end
end
