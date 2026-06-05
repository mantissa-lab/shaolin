require "shaolin"

# The umbrella's contract: a single require loads the whole stack.
RSpec.describe "require \"shaolin\"" do
  it "exposes the version" do
    expect(Shaolin::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "loads the full framework (kernel + every sub-gem's entrypoint)" do
    # one representative constant per sub-gem proves its lib was required
    expect(defined?(Shaolin::Kernel)).to eq("constant")          # core
    expect(defined?(Shaolin::DTO)).to be_truthy                  # dto
    expect(defined?(Shaolin::CQRS::CommandHandler)).to be_truthy # cqrs
    expect(defined?(Shaolin::AR::Migrator)).to be_truthy         # activerecord
    expect(defined?(Shaolin::HTTP::Controller)).to be_truthy     # http
    expect(defined?(Shaolin::Jobs::Reactor)).to be_truthy        # jobs
    expect(defined?(Shaolin::LLM::Client)).to be_truthy          # llm
    expect(defined?(Shaolin::Harness)).to be_truthy              # harness
  end

  it "does NOT pull the CLI command stack into application runtime" do
    # shaolin-cli is a dependency (so the `shaolin` binary installs), but the
    # umbrella must not require the Thor/Prism command stack into a booted
    # app/worker. (The bare `Shaolin::CLI` namespace + VERSION may be defined as
    # a side effect of the gemspec reading its version — that's inert; the CLI's
    # actual commands/generators are what must stay unloaded.)
    expect($LOADED_FEATURES.any? { |f| f.end_with?("shaolin/cli.rb") }).to be(false)
    expect(defined?(Shaolin::CLI::Main)).to be_nil
    expect(defined?(Shaolin::CLI::Generators)).to be_nil
  end
end
