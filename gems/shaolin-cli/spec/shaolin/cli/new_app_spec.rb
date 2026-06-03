require "shaolin/cli"
require "tmpdir"

RSpec.describe Shaolin::CLI::Generators::NewAppGenerator do
  it "scaffolds a runnable application skeleton" do
    Dir.mktmpdir do |root|
      gen = described_class.new(["blog"])
      gen.destination_root = root
      gen.invoke_all

      base = File.join(root, "blog")
      %w[
        Gemfile config/boot.rb bin/server Dockerfile AGENTS.md README.md
        deploy/service.yaml .dockerignore .ruby-version app/modules/.keep
      ].each { |f| expect(File).to exist(File.join(base, f)), "missing #{f}" }

      expect(File.read(File.join(base, ".ruby-version")).strip).to eq("4.0.5")
      expect(File.read(File.join(base, "config/boot.rb"))).to include("module Blog")
    end
  end
end
