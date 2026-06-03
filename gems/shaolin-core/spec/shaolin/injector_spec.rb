require "shaolin/core"
require "support/tmp_app"

RSpec.describe Shaolin::Injector do
  include TmpApp

  it "produces an injector that resolves components from the container" do
    with_module("users", {
      "greeter.rb" => "module Users; class Greeter; def hi = 'hi'; end; end"
    }) do |_root, mod_dir|
      container = Shaolin::ContainerBuilder.build(name: "users", dir: mod_dir)
      import = Shaolin::Injector.for(container)

      klass = Class.new do
        include import["greeter"]
        def call = greeter.hi
      end

      expect(klass.new.call).to eq("hi")
    end
  end

  it "allows overriding an injected dependency (for tests)" do
    with_module("users", {
      "greeter.rb" => "module Users; class Greeter; def hi = 'hi'; end; end"
    }) do |_root, mod_dir|
      container = Shaolin::ContainerBuilder.build(name: "users", dir: mod_dir)
      import = Shaolin::Injector.for(container)

      klass = Class.new do
        include import["greeter"]
        def call = greeter.hi
      end

      fake = Class.new { def hi = "yo" }.new
      expect(klass.new(greeter: fake).call).to eq("yo")
    end
  end
end
