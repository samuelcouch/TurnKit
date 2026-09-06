# frozen_string_literal: true

module Turnkit
  class Delivery < ApplicationRecord
    self.table_name = "<%= table_prefix %>_deliveries"
  end
end
