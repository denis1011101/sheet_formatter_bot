# frozen_string_literal: true

module SheetFormatterBot
  module Utils
    module Constants
      CANCELLED_SLOT_NAMES = [
        "отмена", "отменен", "отменён", "отменено", "отменить",
        "canceled", "cancelled", "cancel"
      ].freeze

      IGNORED_SLOT_NAMES = (
        CANCELLED_SLOT_NAMES +
        [
          "резерв", "reserve", "backup",
          "один корт", "два корта", "три корта", "четыре корта",
          "пять кортов", "шесть кортов", "грунт", "хард"
        ]
      ).freeze

      STATUS_YES    = "yes"
      STATUS_NO     = "no"
      STATUS_MAYBE  = "maybe"

      STATUS_COLORS = {
        STATUS_YES => "green",
        STATUS_NO => "red",
        STATUS_MAYBE => "yellow"
      }.freeze

      COLOR_MAP = {
        'red'    => { red: 1.0, green: 0.0, blue: 0.0 },
        'green'  => { red: 0.0, green: 0.5, blue: 0.0 },
        'blue'   => { red: 0.0, green: 0.0, blue: 1.0 },
        'yellow' => { red: 1.0, green: 0.5, blue: 0.0 },
        'white'  => { red: 1.0, green: 1.0, blue: 1.0 },
        'black'  => { red: 0.0, green: 0.0, blue: 0.0 },
        'none'   => nil
      }.freeze
    end
  end
end
