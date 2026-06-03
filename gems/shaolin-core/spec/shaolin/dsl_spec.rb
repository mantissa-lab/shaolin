require "shaolin/core"

RSpec.describe Shaolin do
  before { Shaolin::Registry.reset! }

  it "builds a ModuleDefinition from the block" do
    defn = Shaolin.module("users") do
      imports "notifications.mailer"
      exports "user_service", "queries.find_user"
      commands_handled "RegisterUser"
      events_published "users.user_registered"
    end

    expect(defn.name).to eq("users")
    expect(defn.imports).to eq(["notifications.mailer"])
    expect(defn.exports).to eq(["user_service", "queries.find_user"])
    expect(defn.commands_handled).to eq(["RegisterUser"])
    expect(defn.events_published).to eq(["users.user_registered"])
  end

  it "accepts event subscriptions via imports(events:)" do
    defn = Shaolin.module("billing_consumer") { imports events: ["billing.invoice_paid"] }
    expect(defn.subscribed_events).to eq(["billing.invoice_paid"])
    expect(defn.imports).to eq([])
  end

  it "registers the module in the Registry" do
    defn = Shaolin.module("users") { exports "user_service" }
    expect(Shaolin::Registry.find("users")).to be(defn)
  end
end
