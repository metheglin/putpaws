require "io/console"
require "tty-prompt"

class Putpaws::Prompt
  def self.safe
    default_args = {output: IO.console || $stderr}
    TTY::Prompt.new(**default_args)
  end
end
