if not lib.checkDependency('es_extended', '1.9.0') then error() end
if not lib.checkDependency('ox_lib', '3.0.0') then error() end
if not lib.checkDependency('ox_inventory', '2.20.0') then error() end

local config = require 'config.config'
local ox_inventory = exports.ox_inventory
local ITEMS = ox_inventory:Items()
local PRODUCTS = require 'config.shop_items'
local LOCATIONS = require 'config.locations'
local ESX = exports['es_extended']:getSharedObject()

ShopData = {}

local function registerShop(shopType, shopData)
    ShopData[shopType] = {}
    if shopData.coords then
        for locationId, locationData in pairs(shopData.coords) do
            local shop = {
                name = shopData.name,
                location = locationId,
                inventory = lib.table.deepclone(shopData.inventory),
                groups = shopData.groups,
                coords = locationData
            }
            ShopData[shopType][locationId] = shop
        end
    else
        local shop = {
            name = shopData.name,
            inventory = lib.table.deepclone(shopData.inventory),
            groups = shopData.groups
        }
        ShopData[shopType][1] = shop
    end
end

lib.callback.register("EF-Shops:Server:OpenShop", function(source, shop_type, location)
    local shop = ShopData[shop_type][location]
    return shop.inventory
end)

local mapBySubfield = function(tbl, subfield)
    local mapped = {}
    for i = 1, #tbl do
        local item = tbl[i]
        mapped[item[subfield]] = item
    end
    return mapped
end

lib.callback.register("EF-Shops:Server:PurchaseItems", function(source, purchaseData)
    if not purchaseData or not purchaseData.shop then
        lib.print.warn(GetPlayerName(source) .. " may be attempting to exploit EF-Shops:Server:PurchaseItems.")
        return false
    end

    local xPlayer = ESX.GetPlayerFromId(source)
    local shop = ShopData[purchaseData.shop.id][purchaseData.shop.location]
    local shopType = purchaseData.shop.id

    if not shop then
        lib.print.error("Invalid shop: " .. purchaseData.shop.id .. " called by: " .. GetPlayerName(source))
        return false
    end

    local shopData = LOCATIONS[purchaseData.shop.id]
    if shopData.jobs then
        if not shopData.jobs[xPlayer.job.name] then
            lib.print.error("Invalid job: " .. xPlayer.job.name .. " for shop: " .. purchaseData.shop.id)
            return false
        end
        if shopData.jobs[xPlayer.job.name] > xPlayer.job.grade then
            lib.print.error("Invalid job grade: " .. xPlayer.job.grade .. " for shop: " .. purchaseData.shop.id)
            return false
        end
    end

    local currency = purchaseData.currency
    local mappedCartItems = mapBySubfield(purchaseData.items, "id")
    local validCartItems = {}
    local totalPrice = 0

    for i = 1, #shop.inventory do
        local shopItem = shop.inventory[i]
        local itemData = ITEMS[shopItem.name]
        local mappedCartItem = mappedCartItems[shopItem.id]

        if mappedCartItem then
            if shopItem.license and not xPlayer.get('licenses')[shopItem.license] then
                TriggerClientEvent('ox_lib:notify', source, {
                    title = "License Required",
                    description = "You need a " .. shopItem.license .. " license.",
                    type = "error"
                })
                goto continue
            end

            if not exports.ox_inventory:CanCarryItem(source, shopItem.name, mappedCartItem.quantity) then
                TriggerClientEvent('ox_lib:notify', source, {
                    title = "Inventory Full",
                    description = "Cannot carry " .. itemData.label,
                    type = "error"
                })
                goto continue
            end

            if shopItem.count and (mappedCartItem.quantity > shopItem.count) then
                TriggerClientEvent('ox_lib:notify', source, {
                    title = "Out of Stock",
                    description = itemData.label .. " is out of stock",
                    type = "error"
                })
                goto continue
            end

            if shopItem.jobs then
                if not shopItem.jobs[xPlayer.job.name] then
                    TriggerClientEvent('ox_lib:notify', source, {
                        title = "Job Required",
                        description = "Wrong job for " .. itemData.label,
                        type = "error"
                    })
                    goto continue
                end
                if shopItem.jobs[xPlayer.job.name] > xPlayer.job.grade then
                    TriggerClientEvent('ox_lib:notify', source, {
                        title = "Grade Required",
                        description = "Insufficient grade for " .. itemData.label,
                        type = "error"
                    })
                    goto continue
                end
            end

            local newIndex = #validCartItems + 1
            validCartItems[newIndex] = mappedCartItem
            validCartItems[newIndex].inventoryIndex = i
            totalPrice = totalPrice + (shopItem.price * mappedCartItem.quantity)
        end
        :: continue ::
    end

    -- Handle payment
    if currency == "cash" then
        if xPlayer.getMoney() < totalPrice then
            TriggerClientEvent('ox_lib:notify', source, {
                title = "Insufficient Funds",
                description = "Not enough cash",
                type = "error"
            })
            return false
        end
        xPlayer.removeMoney(totalPrice)
    else
        if xPlayer.getAccount('bank').money < totalPrice then
            TriggerClientEvent('ox_lib:notify', source, {
                title = "Insufficient Funds",
                description = "Not enough money in bank",
                type = "error"
            })
            return false
        end
        xPlayer.removeAccountMoney('bank', totalPrice)
    end

    -- Process items
    for i = 1, #validCartItems do
        local item = validCartItems[i]
        local itemData = ITEMS[item.name]
        local productData = PRODUCTS[shopData.shopItems][item.id]

        if not itemData or not productData then
            lib.print.error("Invalid item/product: " .. item.name .. " in shop: " .. shopType)
            goto continue
        end

        local success = exports.ox_inventory:AddItem(source, item.name, item.quantity, productData.metadata)
        
        if success then
            if shop.inventory[item.inventoryIndex].count then
                shop.inventory[item.inventoryIndex].count -= item.quantity
            end
        else
            -- Refund if item couldn't be added
            local refundAmount = item.quantity * shop.inventory[item.inventoryIndex].price
            if currency == "cash" then
                xPlayer.addMoney(refundAmount)
            else
                xPlayer.addAccountMoney('bank', refundAmount)
            end
        end
        :: continue ::
    end

    return true
end)

AddEventHandler('onResourceStart', function(resource)
    if GetCurrentResourceName() ~= resource and resource ~= "ox_inventory" then return end

    -- Validate items
    for productType, productData in pairs(PRODUCTS) do
        for _, item in pairs(productData) do
            if not ITEMS[(string.find(item.name, "weapon_") and (item.name):upper()) or item.name] then
                lib.print.error("Invalid Item: ", item, "in product table:", productType, "^7")
                productData[item] = nil
            end
        end
    end

    -- Register shops
    for shopID, shopData in pairs(LOCATIONS) do
        if not shopData.shopItems or not PRODUCTS[shopData.shopItems] then
            lib.print.error("Invalid product ID (" .. shopData.shopItems .. ") for [" .. shopID .. "]")
            goto continue
        end

        local shopProducts = {}
        for item, data in pairs(PRODUCTS[shopData.shopItems]) do
            shopProducts[#shopProducts + 1] = {
                id = tonumber(item),
                name = data.name,
                price = config.fluctuatePrices and (math.round(data.price * (math.random(80, 120) / 100))) or data.price or 0,
                license = data.license,
                metadata = data.metadata,
                count = data.defaultStock,
                jobs = data.jobs
            }
        end

        table.sort(shopProducts, function(a, b)
            return a.name < b.name
        end)

        registerShop(shopID, {
            name = shopData.Label,
            inventory = shopProducts,
            groups = shopData.groups,
            coords = shopData.coords
        })
        :: continue ::
    end
end)
