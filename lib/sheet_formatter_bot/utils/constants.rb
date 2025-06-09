# frozen_string_literal: true

module SheetFormatterBot
  module Utils
    module Constants
      CANCELLED_SLOT_NAMES = [
        "отмена", "отменен", "отменён", "отменено", "отменить", "cancel"
      ].freeze

      IGNORED_SLOT_NAMES = (
        CANCELLED_SLOT_NAMES +
        [
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
    end
  end
end
