# What Chatwoot's onboarding form and profile page would otherwise have you do by hand:
# one account, one administrator, and an API-channel inbox for seeded conversations to
# arrive through. Uses Chatwoot's own models so its validations and callbacks all run —
# the access token, for one, is minted by a callback on User.
require "securerandom"

email = "demo@example.com"
password = "Demo-#{SecureRandom.hex(6)}-A1!"

account = Account.find_or_create_by!(name: "Account Health Demo")
user = User.find_by(email: email) || User.new(email: email, name: "Demo Agent")
if user.new_record?
  user.password = password
  user.password_confirmation = password
  user.skip_confirmation!
  user.save!
end
AccountUser.find_or_create_by!(account: account, user: user) { |au| au.role = :administrator }

inbox = account.inboxes.find_by(name: "Support")
unless inbox
  channel = Channel::Api.create!(account: account)
  inbox = account.inboxes.create!(name: "Support", channel: channel)
end
InboxMember.find_or_create_by!(inbox: inbox, user: user)

File.write("/state/chatwoot.env", <<~ENV)
  CHATWOOT_API_TOKEN=#{user.access_token.token}
  CHATWOOT_ACCOUNT_ID=#{account.id}
  CHATWOOT_INBOX_ID=#{inbox.id}
  CHATWOOT_LOGIN=#{email}
  CHATWOOT_PASSWORD=#{password}
ENV
puts "bootstrap: account #{account.id}, inbox #{inbox.id}"
