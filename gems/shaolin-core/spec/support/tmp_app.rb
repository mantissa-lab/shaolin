require "tmpdir"
require "fileutils"

# Scaffolds synthetic module folders in a tmpdir for kernel specs.
module TmpApp
  # Build a single module folder and yield (root, module_dir).
  def with_module(name, files)
    Dir.mktmpdir("shaolin") do |root|
      mod_dir = File.join(root, "app/modules", name.to_s)
      write_files(mod_dir, files)
      yield root, mod_dir
    end
  end

  # Build a whole app of modules: { "users" => { "module.rb" => "...", ... }, ... }
  def with_app(modules)
    Dir.mktmpdir("shaolin") do |root|
      modules.each do |name, files|
        write_files(File.join(root, "app/modules", name.to_s), files)
      end
      yield root
    end
  end

  private

  def write_files(dir, files)
    FileUtils.mkdir_p(dir)
    files.each do |rel, content|
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end
end
