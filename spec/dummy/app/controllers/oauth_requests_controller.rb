class OauthRequestsController < ApplicationController
  def create
    preserved = nil
    Vouch::OAuthInitiation.new(->(env) {
      preserved = Rack::Request.new(env).GET
      [204, {}, []]
    }).call(request.env)
    render json: preserved
  end
end
