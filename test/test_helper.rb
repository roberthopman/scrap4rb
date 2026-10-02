require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
LIB = File.join(ROOT, "lib")
EXE = File.join(ROOT, "exe", "scrap4rb")
FIXTURE = File.join(__dir__, "fixtures", "sample")
GOLDEN_DIR = File.join(__dir__, "golden")
RUBY = RbConfig.ruby

$LOAD_PATH.unshift LIB
