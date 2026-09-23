require "warden"

Warden::Strategies.add(:password) do
  def store?
    false
  end

  def valid?
    params.present? && params["password"].present?
  end

  def authenticate!
    mapping = Vouch.mapping_for(scope)
    return fail!(I18n.t("vouch.sessions.invalid_credentials")) if mapping.membership_scope?
    account = mapping.account_class.first_by_auth_conditions(params.with_indifferent_access)

    if account && !account.locked? && account.authenticate(params["password"])
      success!(account)
    else
      account.failed_login! if account && !account.locked?
      fail!(I18n.t("vouch.sessions.invalid_credentials"))
    end
  end
end
