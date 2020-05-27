# frozen_string_literal: true

require_relative 'result/ok'
require_relative 'result/error'

#
# A generic representation of success and failure.
#
# Styled after the Result monad of Elm and Rust
# (or the Either monad of Haskell).
#
# The `#and_then` method can be used to chain functions that
# operate on the data held by a result.
#
module Result
  def self.ok(value)
    Ok.new(value)
  end

  def self.error(error)
    Error.new(error)
  end

  # Returns the first result that have succeeded.
  # If not, then returns failed results
  def self.any(*results)
    result = results.find(&:success?)
    if result.nil?
      Result.error(results.map(&:error))
    else
      result
    end
  end
end
