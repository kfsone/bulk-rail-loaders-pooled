data:extend({
    {
        type = "int-setting",
        name = "mbrlp-silo-capacity",
        setting_type = "startup",
        default_value = 96,
        minimum_value = 8,
        maximum_value = 140,
        order = "a"
    },
    {
        type = "int-setting",
        name = "mbrlp-max-silos",
        setting_type = "startup",
        default_value = 16,
        minimum_value = 1,
        maximum_value = 32,
        order = "b"
    }
})
