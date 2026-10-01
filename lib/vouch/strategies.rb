require "warden"

Warden::Strategies.add(:password) do
  def store?
    false
  end

  def valid?
    credentials["password"].present?
  end

  def credentials
    @credentials ||= begin
      key = Vouch.mapping_for(scope).account_param_key.to_s
      value = params.key?(key) ? params[key] : params
      value.is_a?(Hash) ? value.with_indifferent_access : {}.with_indifferent_access
    end
  end

  def authenticate!
    mapping = Vouch.mapping_for(scope)
    return fail!(I18n.t("vouch.sessions.invalid_credentials")) if mapping.membership_scope?
    account = mapping.account_class.first_by_auth_conditions(credentials)

    if account && !account.locked? && account.authenticate(credentials["password"])
      success!(account)
    else
      account.failed_login! if account && !account.locked?
      fail!(I18n.t("vouch.sessions.invalid_credentials"))
    end
  end
end
