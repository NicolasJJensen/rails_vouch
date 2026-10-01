require "rails_helper"

RSpec.describe "Concurrent lockout expiry" do
  self.use_transactional_tests = false

  it "resets the allowance once while counting both failed requests" do
    account = create(:account, failed_attempts: 5, consecutive_locks: 1, locked_at: 10.minutes.ago)
    ready = Queue.new
    start = Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          record = Account.find(account.id)
          ready << true
          start.pop
          record.failed_login!
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    workers.each(&:value)

    expect(account.reload.failed_attempts).to eq(2)
    expect(account.locked_at).to be_nil
    expect(account.consecutive_locks).to eq(1)
  ensure
    workers&.each(&:join)
    account&.destroy!
  end
end
