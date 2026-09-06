# frozen_string_literal: true

module Turnkit
  class Wait < ApplicationRecord
    self.table_name = "<%= table_prefix %>_waits"
  end
end
