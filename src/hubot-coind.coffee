# Description
#   A Hubot script that shows information from a
#   coin daemon and pricing from various exchanges.
#
# Configuration:
#   See config.json
#   You may use HUBOT_COIND_CONFIG env var to
#   set a custom cfg ie: 'config_alt.json'
#
# Commands:
#   hubot about - About this bot
#   hubot active - Count the channel's active users.
#   hubot address - Get a deposit address
#   hubot balance - Show your balance
#   hubot diff - Show difficulty
#   hubot height - Show block height
#   hubot hps - Show network hashrate
#   hubot rain <amount> - Rain on the channel's active users.
#   hubot soak <amount> - Soak the channel with accumulated coins
#   hubot tip <user> <amount> - Tip a specific user or bot
#   hubot withdraw <amount> <address> - Withdraw your coins
#
# Author:
#   upgradeadvice
#

"use strict"
fs = require("fs")
path = require("path")
os = require("os")
jsonminify = require("jsonminify")
daemon = require("coinlib/lib/client.js")
bot = this

is_pm = (msg) ->
  try
    msg.message.user.pm
  catch error
    false

uname = (msg) ->
  try
    msg.message.user.name.toLowerCase()
  catch error
    false

class Actives
  constructor: (@robot) ->
    @cache = {}

    @robot.brain.on 'loaded', @load
    if @robot.brain.data.users.length
      @load()

  load: =>
    if @robot.brain.data.actives
      @cache = @robot.brain.data.actives
    else
      @robot.brain.data.actives = @cache

  add: (user) ->
    @cache[user] =
      date: new Date() - 0

  last: (user) ->
    @cache[user] ? {}

  usersSince: (minutesAgo) ->
    minutes = 60000
    timeSinceActive = new Date(Date.now() - minutesAgo*minutes)
    users = (nick for nick, data of @cache when data.date > timeSinceActive)
    return users

  soak: (@robot, @dest, @msg, date) ->
    end = Math.round(+new Date(date))
    _second = 1000
    _minute = _second * 60
    _hour = _minute * 60
    _day = _hour * 24
    timer = undefined
    mintime = bot.config.minactivetime
    minconf = bot.config.minconf
    symb = bot.config.symb
    soakacct = "_soakacct_"
    showRemaining = ->
      robot.brain.set "soaking", true
      now = Math.round(+new Date())
      distance = end - now
      if distance < 0
        clearInterval timer
        bot.daemon.cmd "getbalance", [soakacct, minconf], (error, response) ->
          soakbalance = parseFloat(response.result)
          amnt = (soakbalance / dest.length)
          if (amnt < bot.config.mintip)
            msg.reply "Sorry, not enough in the bucket to go around.
             ~#{(bot.config.mintip*dest.length) - amnt}#{symb} needed."
            return
          for users in dest
            bot.daemon.cmd "move", [soakacct,users,amnt], (error, response) ->
              if error isnt null
                msg.reply "Sorry, there was an error. Check your syntax."
                robot.logger.error "#{JSON.stringify(error)}
                #{JSON.stringify(response)}"
                return
          msg.reply "[OK] Soaking #{dest.toString()} with #{amnt}#{symb}"
          robot.brain.set "soaking", false
          return
      days: Math.floor(distance / _day)
      hours: Math.floor((distance % _day) / _hour)
      minutes: Math.floor((distance % _hour) / _minute)
      seconds: Math.floor((distance % _minute) / _second)
      return
    timer = setInterval(showRemaining, 1000)
    return

module.exports = (robot) ->
  actives = new Actives robot

  robot.hear /.*/, (msg) ->
    unless is_pm msg
      actives.add (uname msg)

  robot.respond /active/i, (msg) ->
    mintime = bot.config.minactivetime
    actlist = actives.usersSince(mintime)
    actsum = actlist.length
    msg.send "[OK] I see #{actsum} active users."

  robot.respond /soak ([0-9]*\.?[0-9]+)/i, (msg) ->
    mintime = bot.config.minactivetime
    dest = actives.usersSince(mintime)
    destnum = dest.length
    amnt = Number(msg.match[1])
    soakacct = "_soakacct_"
    from = msg.envelope.user.name.toLowerCase()
    minconf = bot.config.minconf
    symb = bot.config.symb
    delay = bot.config.cmddelay
    timestamp = Math.round +new Date() / 1000
    last = robot.brain.get from
    try
      parseFloat(amnt)
    catch ValueError
      msg.reply "The 'amount' argument must be an integer or a floating point"
      return
    if parseFloat(amnt) <= 0
      msg.reply "You can't soak negative amounts, sorry..."
      return
    if last
      if timestamp < (last + delay)
        msg.reply "Please wait #{delay} seconds between soak"
        return
    if isNaN(amnt)
      msg.reply "Usage: soak <amount>"
      return
    bot.daemon.cmd "getbalance", [from, minconf], (error, response) ->
      confirmedBal = parseFloat(response.result)
      if amnt <= confirmedBal
        bot.daemon.cmd "move", [from,soakacct,amnt], (error, response) ->
          if error isnt null
            msg.reply "Sorry, there was an error. Check your syntax."
            robot.logger.error "#{JSON.stringify(error)}
            #{JSON.stringify(response)}"
            return
        msg.reply "[OK] #{from} added #{amnt}#{symb} to the bucket."
        if robot.brain.get("soaking") is true
          bot.daemon.cmd "getbalance", [soakacct, minconf], (e, r) ->
            soakbalance = parseFloat(r.result)
            msg.reply "#{soakbalance}#{symb} will be soaked soon"
            return
        else
          now = Math.round(+new Date())
          interval = (bot.config.soakinterval_minutes  * 1000 * 60)
          time = (now + interval)
          new actives.soak(robot, dest, msg, time)
          bot.daemon.cmd "getbalance", [soakacct, minconf], (e, r) ->
            soakbalance = parseFloat(r.result)
            msg.reply "#{soakbalance}#{symb} will be soaked in about
             #{bot.config.soakinterval_minutes} minutes"
        newtime = Math.round +new Date() / 1000
        robot.brain.set from, newtime
        return
      else
        msg.reply "You don't have enough #{symb}.
         Check your balance and try again."
        return

  robot.respond /height/i, (msg) ->
    bot.daemon.cmd "getinfo", [], (error, response) ->
      blocks = response.result.blocks
      unless blocks
        robot.emit "Error in getinfo: trying to parse current block.", error
        return
      symb = bot.config.symb
      msg.reply "[OK] #{symb} Block Height: #{blocks}"

  robot.respond /address/i, (msg) ->
    who = msg.envelope.user.name.toLowerCase()
    #just get a new address every time
    bot.daemon.cmd "getnewaddress", [who], (error, response) ->
      addr = response.result
      msg.reply "[OK] #{addr}"

  robot.respond /balance/i, (msg) ->
    who = msg.envelope.user.name.toLowerCase()
    minconf = bot.config.minconf
    bot.daemon.cmd "getbalance", [who, minconf], (error, response) ->
      conf = parseFloat(response.result)
      bot.daemon.cmd "getbalance", [who, 0], (error, response) ->
        unconf = parseFloat(response.result)
        bal = parseFloat(unconf - conf)
        symb = bot.config.symb
        msg.send "[OK] Your balance is #{conf.toFixed(8)} #{symb}
         [#{bal.toFixed(8)} unconfirmed (need #{minconf} confirmations)]"

  robot.respond /hps/i, (msg) ->
    bot.daemon.cmd "getnetworkhashps", [], (error, response) ->

      hps = (response.result / 1000000).toFixed(2)
      symb = bot.config.symb
      msg.reply "[OK] #{symb} Current Network Hashrate: #{hps} mh/s"

  robot.respond /diff/i, (msg) ->
    bot.daemon.cmd "getdifficulty", [], (error, response) ->
      diff = response.result
      symb = bot.config.symb
      msg.reply "[OK] #{symb} Current Difficulty:#{diff}"

  robot.respond /tip (.*) ([0-9]*\.?[0-9]+)/i, (msg) ->
    dest = msg.match[1].toLowerCase()
    amnt = Number(msg.match[2])
    from = msg.envelope.user.name.toLowerCase()
    minconf = bot.config.minconf
    symb = bot.config.symb
    delay = bot.config.cmddelay
    users = robot.brain.usersForFuzzyName msg.match[1]
    timestamp = Math.round +new Date() / 1000
    last = robot.brain.get from
    try
      parseFloat(amnt)
    catch ValueError
      msg.reply "The 'amount' argument must be an integer or a floating point"
      return
    if parseFloat(amnt) < 0
      msg.reply "You can't tip negative amounts, sorry..."
      return
    if last
      if timestamp < (last + delay)
        msg.reply "Please wait #{delay} seconds between tips"
        return
    if isNaN(amnt)
      msg.reply "Usage: tip <dest> <amount>"
      return
    else if dest is from
      msg.reply "Stop tipping yourself."
      return
    else if (amnt < bot.config.mintip)
      msg.reply "Sorry, the minimum tip is #{bot.config.mintip}"
      return
    bot.daemon.cmd "getbalance", [from, minconf], (error, response) ->
      confirmedBal = parseFloat(response.result)
      if amnt <= confirmedBal
        bot.daemon.cmd "move", [from,dest,amnt], (error, response) ->
          if error isnt null
            msg.reply "Sorry, there was an error. Check your syntax."
            robot.logger.error "#{JSON.stringify(error)}
            #{JSON.stringify(response)}"
            return
          msg.reply "[OK] #{from} tipped #{dest} #{amnt}#{symb}."
          newtime = Math.round +new Date() / 1000
          robot.brain.set from, newtime
          return
      else
        msg.reply "You don't have enough #{symb}.
         Check your balance and try again."
        return

  robot.respond /about/i, (msg) ->
    msg.reply "I was coded by upgradeadvice in the middle of the night."

  robot.respond /withdraw (.*) (.*)/i, (msg) ->
    dest = msg.match[2]
    amnt = Number(msg.match[1])
    from = msg.envelope.user.name.toLowerCase()
    minconf = bot.config.minconf
    symb = bot.config.symb
    delay = bot.config.cmddelay
    fee = bot.config.fee
    botname = robot.name.toLowerCase()
    users = robot.brain.usersForFuzzyName msg.match[1]
    timestamp = Math.round +new Date() / 1000
    last = robot.brain.get from
    try
      parseFloat(amnt)
    catch ValueError
      msg.reply "The 'amount' argument must be an integer or a floating point"
      return
    if parseFloat(amnt) < 0
      msg.reply "You can't withdraw negative amounts, sorry..."
      return
    if last
      if timestamp < (last + delay)
        msg.reply "Please wait #{delay} seconds between withdrawals"
        return
    if isNaN(amnt)
      msg.reply "Usage: withdraw <amount> <address>"
      return
    else if (amnt < bot.config.minwithdraw)
      msg.reply "Sorry, the minimum withdraw is #{bot.config.minwithdraw}"
      return
    try
      bot.daemon.cmd "validateaddress", [dest], (error, response) ->
        isvalid = JSON.parse(response.result.isvalid)
        if isvalid isnt true
          msg.reply "Sorry, the destination isn't a valid #{symb} address."
          return
        else
          bot.daemon.cmd "getbalance", [from, minconf], (error, response) ->
            confirmedBal = parseFloat(response.result)
            if amnt <= confirmedBal - fee
              bot.daemon.cmd "sendfrom", [from,dest,amnt,minconf], (e, r) ->
                if e isnt null
                  msg.reply "Sorry, there was an error. Check your syntax."
                  robot.logger.error "#{JSON.stringify(e)}
                  #{JSON.stringify(r)}"
                  return
                confirm = JSON.stringify(r.result)
                msg.reply "[OK] Withdrawing #{amnt}#{symb} to #{dest}."
                msg.reply "TXID: #{confirm}"
                bot.daemon.cmd "move", [from,botname,fee], (error, response) ->
                  if error isnt null
                    msg.reply "There was an error processing fees."
                    robot.logger.error "#{JSON.stringify(error)}
                    #{JSON.stringify(response)}"
                    return
                newtime = Math.round +new Date() / 1000
                robot.brain.set from, newtime
                return
            else
              msg.reply "You don't have enough #{symb}.
               Check your balance and try again."
              msg.reply "The withdraw fee is #{fee}.
               #{symb} + standard #{symb} network fees."
              return

  robot.respond /rain ([0-9]*\.?[0-9]+)/i, (msg) ->
    mintime = bot.config.minactivetime
    dest = actives.usersSince(mintime)
    destnum = dest.length
    amnt = Number(msg.match[1])
    rainamnt = (amnt/destnum)
    from = msg.envelope.user.name.toLowerCase()
    minconf = bot.config.minconf
    symb = bot.config.symb
    delay = bot.config.cmddelay
    timestamp = Math.round +new Date() / 1000
    last = robot.brain.get from
    try
      parseFloat(amnt)
    catch ValueError
      msg.reply "The 'amount' argument must be an integer or a floating point"
      return
    if parseFloat(amnt) <= 0
      msg.reply "You can't rain negative amounts, sorry..."
      return
    if last
      if timestamp < (last + delay)
        msg.reply "Please wait #{delay} seconds between rain"
        return
    if isNaN(amnt)
      msg.reply "Usage: rain <amount>"
      return
    else if (rainamnt < bot.config.mintip)
      msg.reply "Sorry, not enough to go around.
       ~#{bot.config.mintip*destnum}#{symb} needed."
      return
    bot.daemon.cmd "getbalance", [from, minconf], (error, response) ->
      confirmedBal = parseFloat(response.result)
      if amnt <= confirmedBal
        for users in dest
          bot.daemon.cmd "move", [from,users,rainamnt], (error, response) ->
            if error isnt null
              msg.reply "Sorry, there was an error. Check your syntax."
              robot.logger.error "#{JSON.stringify(error)}
              #{JSON.stringify(response)}"
              return
        msg.reply "[OK] #{from} rained #{rainamnt}#{symb}
         on #{dest.toString()}"
        newtime = Math.round +new Date() / 1000
        robot.brain.set from, newtime
        return
      else
        msg.reply "You don't have enough #{symb}.
         Check your balance and try again."
        return



  initialize = ->
    readConfig ->
      setupDaemon ->
      return
    return

  readConfig = (callback) ->
    if process.env.HUBOT_COIND_CONFIG
      cfg = process.env.HUBOT_COIND_CONFIG
      config = __dirname + '/../' + cfg
    else config = __dirname + '/../config.json'

    unless config
      robot.logger.error "Main configuration file config.json does not exist."
      return
    data = fs.readFileSync(config, { encoding: 'utf8' })
    bot.config = JSON.parse(JSON.minify(data))
    callback()
    return

  setupDaemon = (callback) ->
    bot.daemon = new daemon(bot.config.daemon)
    robot.logger.info "Waiting for coin daemon connection.."
    bot.daemon.once "online", ->
      robot.logger.info "Coin daemon connection succeded
       #{bot.config.daemon.host}:#{bot.config.daemon.port}"
      callback()
      return
    return

  initialize()
