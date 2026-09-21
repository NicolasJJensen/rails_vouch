# frozen_string_literal: true

require "rails_helper"
require "timeout"

# These examples deliberately run outside RSpec's per-example transaction.
# Each worker checks out its own database connection, so the row locks tested
# here are real PostgreSQL locks rather than nested savepoints on one session.
RSpec.describe "single-use authentication concurrency" do
  uses_transaction "verification nonce permits only one concurrent consumer",
                   "sign-in nonce permits only one concurrent consumer",
                   "second-factor nonce permits only one concurrent consumer",
                   "reset_password_with_token! consumes one token only once",
                   "TokenVerifiable consumes one token only once",
                   "TokenVerifiable returns invalid when a token row is deleted before its row lock",
                   "BackupCodable consumes one code only once",
                   "Recoverable rechecks lockout after waiting for the row lock",
                   "does not reset an active verification lockout when a queued failure arrives",
                   "serializes concurrent last-factor removals through the account lock",
                   "increments verification_version for concurrent subject updates",
                   "preserves version history when a stale object saves A B A edits"

  def concurrently
    ready = Queue.new
    release = Queue.new
    workers = 2.times.map do
      Thread.new do
        Thread.abort_on_exception = true
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          yield
        end
      end
    end

    Timeout.timeout(30) do
      2.times { ready.pop }
      2.times { release << true }
      workers.map(&:value)
    end
  ensure
    2.times { release << true rescue nil }
    workers&.each { |worker| worker.join(5) }
  end

  def concurrently_after_lock_precheck(klass, id)
    ready = Queue.new
    release = Queue.new
    instances = 2.times.map { klass.find(id) }
    workers = instances.map do |instance|
      Thread.new do
        Thread.abort_on_exception = true
        ActiveRecord::Base.connection_pool.with_connection do
          original_lock = instance.method(:lock!)
          first_lock = true
          instance.define_singleton_method(:lock!) do |*args, **kwargs|
            if first_lock
              first_lock = false
              ready << true
              release.pop
            end
            original_lock.call(*args, **kwargs)
          end
          yield instance
        end
      end
    end

    Timeout.timeout(30) do
      2.times { ready.pop }
      2.times { release << true }
      workers.map(&:value)
    end
  ensure
    2.times { release << true rescue nil }
    workers&.each { |worker| worker.join(5) }
  end

  def concurrently_token_consumption(token)
    ready = Queue.new
    release = Queue.new
    allow(InvitationLink).to receive(:lock).and_wrap_original do |original, *args, **kwargs|
      ready << true
      release.pop
      original.call(*args, **kwargs)
    end
    workers = 2.times.map do
      Thread.new do
        Thread.abort_on_exception = true
        ActiveRecord::Base.connection_pool.with_connection do
          InvitationLink.consume_token(token).ok?
        end
      end
    end

    Timeout.timeout(30) do
      2.times { ready.pop }
      2.times { release << true }
      workers.map(&:value)
    end
  ensure
    2.times { release << true rescue nil }
    workers&.each { |worker| worker.join(5) }
  end

  def concurrently_on_preloaded(klass, id)
    ready = Queue.new
    release = Queue.new
    instances = 2.times.map { klass.find(id) }
    workers = instances.map do |instance|
      Thread.new do
        Thread.abort_on_exception = true
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          yield instance
        end
      end
    end

    Timeout.timeout(30) do
      2.times { ready.pop }
      2.times { release << true }
      workers.map(&:value)
    end
  ensure
    2.times { release << true rescue nil }
    workers&.each { |worker| worker.join(5) }
  end

  it "reset_password_with_token! consumes one token only once" do
    account = create(:account, email_address: "reset-concurrency-#{SecureRandom.hex(8)}@example.com")
    token = account.generate_password_reset_token!.value

    results = concurrently_after_lock_precheck(Account, account.id) do |candidate|
      candidate.reset_password_with_token!(token, password: "replacement123")
    end

    expect(results.count(&:ok?)).to eq(1)
    expect(results.count(&:invalid?)).to eq(1)
  ensure
    account&.destroy!
  end

  it "serializes concurrent last-factor removals through the account lock" do
    account = create(:account, email_address: "mfa-removal-concurrency-#{SecureRandom.hex(8)}@example.com")
    account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    account.enable_two_factor!
    ready = Queue.new
    release = Queue.new
    credentials = 2.times.map { |index| TwoFactorCredential.find(account.two_factor_credentials.order(:id).offset(index).pick(:id)) }
    workers = credentials.map do |credential|
      Thread.new do
        Thread.abort_on_exception = true
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          release.pop
          begin
            credential.destroy&.destroyed?
          rescue Vouch::TwoFactorable::LastFactorRemoval
            :last_factor
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    results = workers.map(&:value)

    expect(results).to contain_exactly(true, :last_factor)
    expect(account.reload).to be_two_factor_enabled
    expect(account.two_factor_credentials.where.not(two_factor_enabled_at: nil).count).to eq(1)
  ensure
    account&.disable_two_factor! if account&.persisted? && account.respond_to?(:two_factor_enabled?) && account.two_factor_enabled?
    account&.destroy!
  end

  it "TokenVerifiable consumes one token only once" do
    invitation = create(:invitation_link)
    token = invitation.confirmation_token

    results = concurrently_token_consumption(token)

    expect(results).to contain_exactly(true, false)
  ensure
    invitation&.destroy!
  end

  it "TokenVerifiable returns invalid when a token row is deleted before its row lock" do
    invitation = create(:invitation_link)
    token = invitation.confirmation_token
    reached_lock = Queue.new
    release_lock = Queue.new
    deletion_ready = Queue.new
    release_deletion = Queue.new
    deleter = consumer = nil

    allow(InvitationLink).to receive(:lock).and_wrap_original do |original, *args, **kwargs|
      if Thread.current[:token_consumer]
        reached_lock << true
        Timeout.timeout(30) { release_lock.pop }
      end
      original.call(*args, **kwargs)
    end

    Timeout.timeout(30) do
      deleter = Thread.new do
        Thread.current.abort_on_exception = true
        ActiveRecord::Base.connection_pool.with_connection do
          InvitationLink.transaction do
            InvitationLink.find(invitation.id).lock!.delete
            deletion_ready << true
            Timeout.timeout(30) { release_deletion.pop }
          end
        end
      end
      Timeout.timeout(30) { deletion_ready.pop }

      consumer = Thread.new do
        Thread.current.abort_on_exception = true
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:token_consumer] = true
          InvitationLink.consume_token(token)
        end
      end
      Timeout.timeout(30) { reached_lock.pop }
      release_deletion << true
      release_lock << true

      expect(Timeout.timeout(30) { consumer.value }).to be_invalid
      deleter.join
    end
  ensure
    release_lock << true rescue nil
    release_deletion << true rescue nil
    consumer&.join(5)
    deleter&.join(5)
  end

  it "BackupCodable consumes one code only once" do
    account = create(:account, email_address: "backup-concurrency-#{SecureRandom.hex(8)}@example.com")
    credential = account.two_factor_credentials.create!(
      verified_at: Time.current,
      two_factor_enabled_at: Time.current
    )
    code = credential.regenerate_backup_codes!(count: 1).value.first

    results = concurrently_after_lock_precheck(TwoFactorCredential, credential.id) do |candidate|
      candidate.consume_backup_code!(code)
    end

    expect(results.count(&:ok?)).to eq(1)
    expect(results.count(&:invalid?)).to eq(1)
  ensure
    account&.destroy!
  end

  it "Recoverable rechecks lockout after waiting for the row lock" do
    account = create(:account, email_address: "recovery-concurrency-#{SecureRandom.hex(8)}@example.com")
    account.generate_recovery_codes!
    threshold = Account.auth_config(:recoverable, :max_attempts)
    account.update!(recovery_attempts: threshold - 1)

    results = concurrently_after_lock_precheck(Account, account.id) do |candidate|
      candidate.consume_recovery_code!("WRONG-CODE")
    end

    expect(results.count(&:invalid?)).to eq(1)
    expect(results.count(&:locked?)).to eq(1)
    account.reload
    expect(account.recovery_attempts).to eq(threshold)
    expect(account.recovery_locked_at).to be_present
  ensure
    account&.destroy!
  end

  it "does not reset an active verification lockout when a queued failure arrives" do
    phone = PhoneVerification.create!(e164: "+614#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}")
    threshold = Vouch.configuration.verifiable.max_attempts
    phone.update!(verification_attempts: threshold - 1)
    first_locked_at = 1.minute.ago
    row_locked = Queue.new
    release = Queue.new
    request_started = Queue.new

    holder = Thread.new do
      Thread.abort_on_exception = true
      ActiveRecord::Base.connection_pool.with_connection do
        PhoneVerification.transaction do
          locked = PhoneVerification.find(phone.id)
          locked.lock!
          locked.update!(verification_attempts: threshold, verification_locked_at: first_locked_at)
          row_locked << true
          release.pop
        end
      end
    end

    row_locked.pop
    queued_failure = Thread.new do
      Thread.abort_on_exception = true
      ActiveRecord::Base.connection_pool.with_connection do
        candidate = PhoneVerification.find(phone.id)
        request_started << true
        candidate.send(:bump_verification_lockout!)
      end
    end
    request_started.pop
    sleep 0.05
    release << true

    Timeout.timeout(30) do
      holder.join
      queued_failure.join
    end

    phone.reload
    expect(phone.verification_attempts).to eq(threshold + 1)
    expect(phone.verification_locked_at).to be_within(0.01).of(first_locked_at)
  ensure
    phone&.destroy!
  end

  it "increments verification_version for concurrent subject updates" do
    phone = PhoneVerification.create!(e164: "+614#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}")
    challenge = phone.start_verification!
    code = phone.last_delivered_code
    first = "+614#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}"
    second = "+614#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}"
    values = Queue.new
    values << first
    values << second

    results = concurrently_on_preloaded(PhoneVerification, phone.id) do |candidate|
      candidate.update!(e164: values.pop)
    end

    expect(results).to all(be true)
    phone.reload
    expect(phone.verification_version).to eq(2)
    expect(phone.complete_verification!(code, token: challenge.token)).to be_invalid
  ensure
    phone&.destroy!
  end

  it "preserves version history when a stale object saves A B A edits" do
    phone = PhoneVerification.create!(e164: "+614#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}")
    challenge = phone.start_verification!
    code = phone.last_delivered_code
    stale = PhoneVerification.find(phone.id)
    stale.e164 = "+614#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}"

    other = PhoneVerification.find(phone.id)
    other.update!(e164: "+614#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}")
    stale.e164 = phone.e164
    stale.save!

    expect(stale.reload.verification_version).to eq(3)
    expect(PhoneVerification.find(phone.id).complete_verification!(code, token: challenge.token)).to be_invalid
  ensure
    phone&.destroy!
  end
  it "verification nonce permits only one concurrent consumer" do
    phone = PhoneVerification.create!(e164: "+614#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}")
    challenge = phone.start_verification!
    code = phone.last_delivered_code
    results = concurrently_after_lock_precheck(PhoneVerification, phone.id) do |candidate|
      candidate.complete_verification!(code, token: challenge.token)
    end
    expect(results.count(&:ok?)).to eq(1)
    expect(results.count(&:invalid?)).to eq(1)
  ensure
    phone&.destroy!
  end

  it "sign-in nonce permits only one concurrent consumer" do
    phone = PhoneVerification.create!(e164: "+614#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}")
    challenge = phone.issue_sign_in_code!
    code = phone.last_delivered_sign_in_code
    results = concurrently_after_lock_precheck(PhoneVerification, phone.id) do |candidate|
      candidate.verify_sign_in_code(code, token: challenge.token)
    end
    expect(results.count(&:ok?)).to eq(1)
    expect(results.count(&:invalid?)).to eq(1)
  ensure
    phone&.destroy!
  end

  it "second-factor nonce permits only one concurrent consumer" do
    account = create(:account, email_address: "nonce-concurrency-#{SecureRandom.hex(8)}@example.com")
    credential = account.two_factor_credentials.create!(verified_at: Time.current, two_factor_enabled_at: Time.current)
    code = nil
    credential.define_singleton_method(:deliver_two_factor_code) { |value| code = value }
    challenge = credential.challenge!
    results = concurrently_after_lock_precheck(TwoFactorCredential, credential.id) do |candidate|
      candidate.verify_challenge(code, token: challenge.token)
    end
    expect(results.count(&:ok?)).to eq(1)
    expect(results.count(&:invalid?)).to eq(1)
  ensure
    account&.destroy!
  end

end
