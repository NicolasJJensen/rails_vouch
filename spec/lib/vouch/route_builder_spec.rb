# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vouch::RouteBuilder do
  let(:route_paths) { Rails.application.routes.routes.map { |r| r.path.spec.to_s } }

  describe "route generation" do
    it "infers a single-model scope from a model string or class" do
      expect(Vouch::Mapping.inferred_scope_name(model: "User")).to eq(:user)
      expect(Vouch::Mapping.inferred_scope_name(model: User)).to eq(:user)
    end

    it "infers split-model scopes from the identity reference" do
      expect(Vouch::Mapping.inferred_scope_name(identity: "User")).to eq(:user)
      expect(Vouch::Mapping.inferred_scope_name(identity: User)).to eq(:user)
    end

    it "preserves namespaces when inferring a scope" do
      expect(Vouch::Mapping.inferred_scope_name(model: "Admin::User")).to eq(:admin_user)
      expect(Vouch::Mapping.inferred_scope_name(model: "Admin/User")).to eq(:admin_user)
      stub_const("Admin::User", Class.new)
      expect(Vouch::Mapping.inferred_scope_name(model: Admin::User)).to eq(:admin_user)
    end

    it "retains an explicitly supplied scope when model inference is available" do
      mapping = Vouch::Mapping.new(:staff, model: "User")

      expect(mapping.scope_name).to eq(:staff)
    end

    it "allows the route DSL to infer a single-model scope" do
      test_routes = ActionDispatch::Routing::RouteSet.new
      test_routes.draw do
        Vouch::RouteBuilder.new(self).scope(model: "Account") { |auth| auth.sessions }
      end

      expect(Vouch.mapping_for(:account).account_class_name).to eq("Account")
    ensure
      Vouch.deregister_mapping(:account)
    end

    it "rejects replacing a scope with a different model configuration" do
      test_routes = ActionDispatch::Routing::RouteSet.new
      stub_const("InferenceCollision", Class.new)
      test_routes.draw do
        Vouch::RouteBuilder.new(self).scope(:inference_collision, model: "Account") { |auth| auth.sessions }
      end

      expect {
        test_routes.draw do
          Vouch::RouteBuilder.new(self).scope(model: "InferenceCollision") { |auth| auth.sessions }
        end
      }.to raise_error(Vouch::ConfigurationError, /already mapped to a different model/i)
    ensure
      Vouch.deregister_mapping(:inference_collision)
    end

    it "rejects an anonymous model when scope inference cannot produce a name" do
      expect {
        Vouch::RouteBuilder.new(ActionDispatch::Routing::RouteSet.new).scope(model: Class.new) { |auth| auth.sessions }
      }.to raise_error(Vouch::ConfigurationError, /infer a valid authentication scope/i)
    end

    it "generates session routes" do
      expect(route_paths).to include("/users/sign_in(.:format)")
      expect(route_paths).to include("/users/sign_out(.:format)")
      expect(route_paths).to include("/users/sign_up(.:format)")
    end

    it "registers the mapping in Vouch.mappings" do
      mapping = Vouch.mapping_for(:user)

      expect(mapping).to be_a(Vouch::Mapping)
      expect(mapping.account_class_name).to eq("Account")
      expect(mapping.identity_class_name).to eq("User")
      expect(mapping.tenant_class_name).to eq("Organisation")
    end

    it "requires explicit route selection" do
      routes = ActionDispatch::Routing::RouteSet.new
      expect {
        routes.draw do
          Vouch::RouteBuilder.new(self).scope(:minimal, model: "Account")
        end
      }.to raise_error(Vouch::ConfigurationError, /requires a route block.*auth\.sessions/i)
    end

    it "rejects a mapping whose reserved Warden scopes overlap an existing mapping" do
      test_routes = ActionDispatch::Routing::RouteSet.new
      test_routes.draw do
        Vouch::RouteBuilder.new(self).scope(:collision_source, model: "Account") { |auth| auth.sessions }
      end

      expect {
        test_routes.draw do
          Vouch::RouteBuilder.new(self).scope(:collision_source_account, model: "Account") { |auth| auth.sessions }
        end
      }.to raise_error(Vouch::ConfigurationError, /Warden scope.*reserved.*collision_source_account/i)
    ensure
      Vouch.deregister_mapping(:collision_source)
      Vouch.deregister_mapping(:collision_source_account)
    end

    it "rejects the reverse derived-scope collision" do
      test_routes = ActionDispatch::Routing::RouteSet.new
      test_routes.draw do
        Vouch::RouteBuilder.new(self).scope(:reverse_collision_account, model: "Account") { |auth| auth.sessions }
      end

      expect {
        test_routes.draw do
          Vouch::RouteBuilder.new(self).scope(:reverse_collision, model: "Account") { |auth| auth.sessions }
        end
      }.to raise_error(Vouch::ConfigurationError, /Warden scope.*reverse_collision_account/i)
    ensure
      Vouch.deregister_mapping(:reverse_collision)
      Vouch.deregister_mapping(:reverse_collision_account)
    end

    it "permits replacement of the same mapping scope during a route reload" do
      test_routes = ActionDispatch::Routing::RouteSet.new
      2.times do
        test_routes.draw do
          Vouch::RouteBuilder.new(self).scope(:reloadable_member, model: "Account") { |auth| auth.sessions }
        end
      end

      expect(Vouch.mapping_for(:reloadable_member)).to be_a(Vouch::Mapping)
    ensure
      Vouch.deregister_mapping(:reloadable_member)
    end

    it "uses configured OAuth callback methods and paths" do
      test_routes = ActionDispatch::Routing::RouteSet.new
      test_routes.draw do
        Vouch::RouteBuilder.new(self).scope(
          :member,
          model: "Account",
          oauth_callback_path: "/members/oauth/:provider/callback",
          oauth_failure_path: "/members/oauth/failure",
          oauth_callback_methods: %i[get post],
          oauth_failure_methods: :post
        ) { |auth| auth.oauth_callbacks }
      end

      routes = test_routes.routes.map { |route| [route.verb, route.path.spec.to_s] }
      expect(routes).to include(["GET", "/members/oauth/:provider/callback(.:format)"])
      expect(routes).to include(["POST", "/members/oauth/:provider/callback(.:format)"])
      expect(routes).to include(["POST", "/members/oauth/failure(.:format)"])
    ensure
      Vouch.deregister_mapping(:member)
    end

    it "generates user selection routes" do
      expect(route_paths).to include("/users/select(.:format)")
    end
  end

  describe "#scope with a block" do
    after do
      Vouch.mappings.delete(:member)
    end

    it "only generates routes for features called in the block" do
      test_routes = ActionDispatch::Routing::RouteSet.new
      test_routes.draw do
        Vouch::RouteBuilder.new(self).scope(:member, model: "Account") do |auth|
          auth.sessions
          auth.passwords
        end
      end

      member_paths = test_routes.routes.map { |r| r.path.spec.to_s }

      expect(member_paths).to include("/members/sign_in(.:format)")
      expect(member_paths).to include("/members/password/new(.:format)")

      expect(member_paths).not_to include("/members/sign_up(.:format)")
      expect(member_paths).not_to include("/members/select(.:format)")
      expect(member_paths).not_to include("/members/two_factor_challenges(.:format)")
      expect(member_paths).not_to include("/members/invitation(.:format)")
      expect(member_paths).not_to include("/members/impersonations/:id(.:format)")
    end

    it "restores the outer mapping context after a nested scope" do
      test_routes = ActionDispatch::Routing::RouteSet.new

      test_routes.draw do
        Vouch::RouteBuilder.new(self).scope(:outer, model: "Account") do |auth|
          auth.scope(:inner, model: "Account") { |nested| nested.sessions }
          auth.sessions
        end
      end

      paths = test_routes.routes.map { |route| route.path.spec.to_s }
      expect(paths).to include("/outers/sign_in(.:format)")
      expect(paths).to include("/inners/sign_in(.:format)")
    ensure
      Vouch.deregister_mapping(:outer)
      Vouch.deregister_mapping(:inner)
    end

    it "does not publish an invalid mapping or leave the current mapping behind" do
      test_routes = ActionDispatch::Routing::RouteSet.new
      builder = nil
      expect {
        test_routes.draw do
          builder = Vouch::RouteBuilder.new(self)
          builder.scope(:broken,
            account: "Account", identity: "User",
            associations: { account_identities: :missing_users }) { |auth| auth.sessions }
        end
      }.to raise_error(Vouch::ConfigurationError)

      expect(Vouch.registered_scope?(:broken)).to be(false)
      expect(builder.instance_variable_get(:@current_mapping)).to be_nil
    end

    it "rejects an enabled 2FA scope with an empty explicit association list" do
      test_routes = ActionDispatch::Routing::RouteSet.new

      expect {
        test_routes.draw do
          Vouch::RouteBuilder.new(self).scope(:empty_two_factor_associations,
            account: "Account", identity: "User", associations: { two_factorable: [] }) do |auth|
            auth.sessions
            auth.two_factor
          end
        end
      }.to raise_error(Vouch::ConfigurationError, /two_factorable.*no has_many target/i)

      expect(Vouch.registered_scope?(:empty_two_factor_associations)).to be(false)
    end
  end

  describe "Warden scope registration" do
    it "registers the :user scope in Warden" do
      env = Rack::MockRequest.env_for("/", method: "POST",
        params: { "password" => "test", "email_address" => "test@test.com" })
      env["rack.session"] = {}
      strategy = Warden::Strategies[:password].new(env, :user)
      expect(strategy.scope).to eq(:user)
    end

    it "registers the impersonation scope via the impersonation route helper" do
      expect(route_paths).to include("/users/impersonations/:id(.:format)")
      expect(route_paths).to include("/users/impersonations(.:format)")
    end

    it "resolves the current identity class when a serializer survives a reload" do
      first_identity = Class.new do
        def self.primary_key = :id
        def self.find_by(id:)
          [:first, id]
        end
      end
      second_identity = Class.new do
        def self.primary_key = :id
        def self.find_by(id:)
          [:second, id]
        end
      end
      account = Struct.new(:id, :password_digest).new(1, "x" * 32)
      mapping = double(scope_name: :reload_spec_scope,
                       identity_class: first_identity,
                       account_for: account)

      described_class.new(ActionDispatch::Routing::RouteSet.new)
        .send(:register_warden_scope, mapping)
      allow(mapping).to receive(:identity_class).and_return(first_identity, second_identity)

      serializer = Warden::SessionSerializer.new({})
      expect(serializer.reload_spec_scope_deserialize([1, Vouch::PendingAuthentication.fingerprint(account)]).first).to eq(:first)
      expect(serializer.reload_spec_scope_deserialize([2, Vouch::PendingAuthentication.fingerprint(account)]).first).to eq(:second)
    end

    it "rejects malformed primary and account session payloads without raising" do
      account = Struct.new(:id, :password_digest).new(1, "x" * 32)
      identity_class = Class.new
      identity_class.define_singleton_method(:primary_key) { :id }
      identity_class.define_singleton_method(:find_by) { |id:| Struct.new(:account).new(account) }
      account_class = Class.new
      account_class.define_singleton_method(:primary_key) { :id }
      account_class.define_singleton_method(:find_by) { |id:| account }
      mapping = double(scope_name: :malformed_spec_scope,
                       account_scope_name: :malformed_spec_scope_account,
                       identity_class: identity_class,
                       account_class: account_class,
                       account_for: account)

      described_class.new(ActionDispatch::Routing::RouteSet.new).send(:register_warden_scope, mapping)
      described_class.new(ActionDispatch::Routing::RouteSet.new).send(:register_account_scope, mapping)

      serializer = Warden::SessionSerializer.new({})
      expect { serializer.malformed_spec_scope_deserialize([1, "short"]) }.not_to raise_error
      expect(serializer.malformed_spec_scope_deserialize([1, "short"])).to be_nil
      expect { serializer.malformed_spec_scope_account_deserialize([1, "short"]) }.not_to raise_error
      expect(serializer.malformed_spec_scope_account_deserialize([1, "short"])).to be_nil
    end
  end
end
