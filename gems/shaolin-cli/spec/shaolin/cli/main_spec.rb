require "shaolin/cli"
require "shaolin/cli/main"
require "tmpdir"

RSpec.describe Shaolin::CLI::Main do
  it "g module scaffolds into the current directory" do
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        described_class.start(%w[g module gadgets])
      end
      expect(File).to exist(File.join(root, "app/modules/gadgets/controllers/gadgets_controller.rb"))
      expect(File).to exist(File.join(root, "app/modules/gadgets/gadget.rb"))
    end
  end

  it "server fails clearly outside a shaolin app" do
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        expect { described_class.start(%w[server]) }.to raise_error(SystemExit)
      end
    end
  end
end
