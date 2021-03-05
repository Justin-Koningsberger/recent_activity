#! /usr/bin/env ruby

require 'json'
require 'time'
require 'active_support/all'
require 'diffy'
require 'pry'

unless ARGV.size == 1
  puts "usage: ./recent_activity.rb <number of days inactive>"
  exit
end

@since = ARGV.first.to_i.days.ago.to_date

opts = {}
IO.readlines("config.txt").each do |ec|
  a = ec.strip.split(/\s*=\s*/)
  opts[a[0]] = a[1]
end

board = opts["BOARD"]
@key = opts["KEY"]
@token = opts["TOKEN"]

@board_actions = JSON.parse(`curl "https://trello.com/1/boards/#{board}/actions?/?fields=all&key=#{@key}&token=#{@token}"`)
@board_actions.select! { |action| action["type"] == "deleteCard" || action["type"] == "deleteCheckItem" }
@board_actions.sort_by! {|action| Time.parse(action["date"])}

lists = `curl "https://trello.com/1/boards/#{board}/lists?cards=none&card_fields=name&filter=all&key=#{@key}&token=#{@token}"`
@lists= JSON.parse(lists)

cards = []
before = Time.now.to_date + 1
cards_left = true
limit = 10

while cards_left do
  new_cards = JSON.parse(`curl "https://api.trello.com/1/boards/#{board}/cards/?limit=#{limit}&before=#{before}&filter=all&actions=all&key=#{@key}&token=#{@token}"`)
  new_cards.each { |card| card["dateLastActivity"] = Time.parse(card["dateLastActivity"])}
  new_cards.sort_by! { |card| card["dateLastActivity"] }
  cards_left = false if new_cards.size == 1 && cards.map {|c| c = c['id']}.include?(new_cards[0]['id'])
  cards_left = false if new_cards == []
  if cards_left
    cards += new_cards
    before = new_cards.first['id']
  end
  cards_left = false if new_cards.first["dateLastActivity"] < @since
end

cards.each { |card| card["listname"] = @lists.select { |l| l["id"] == card["idList"] }[0]["name"] }
cards.select! { |card| card["dateLastActivity"] >= @since }

def labels(card)
  labels = []
  card["labels"].each { |l| labels << l["name"] unless l["name"] == "" }
  labels
end

def card_actions(card_actions)
  card_actions.select! do |action|
    Time.parse(action["date"]) >= @since
  end
  card_actions.reverse!

  card_actions.each do |action|
    puts "  #{action["type"]}"
    puts "    performed at: #{action["date"]}" unless action["date"].nil?
    if action["memberCreator"].nil?
      puts "    Person that performed this action was not stored"
    else
      puts "    performed by: #{action["memberCreator"]["fullName"]}"
    end
    describe_action(action)
  end
end

def describe_action(action)
  case action["type"]
  when "addMemberToCard"
    add_member(action)
  when "createCard"
    true
  when "copyCard"
    copy_card(action)
  when "copyCommentCard"
    copy_comment_card(action)
  when "updateCard"
    update_card(action)
  when "moveCardToBoard"
    move_card_board(action)
  when "commentCard"
    comment(action)
  when "deleteCard"
    delete_card(action)
  when "addAttachmentToCard"
    attachment_added(action)
  when "addChecklistToCard"
    checklist_added(action)
  when "updateCheckItemStateOnCard"
    update_check_item(action)
  when "changedChecklistItem"
    checklist_item_changed(action)
  else
    Pry::ColorPrinter.pp(action)
  end
  puts
end

def describe_card(card)
  puts "name: #{card["name"]}"
  puts "id: #{card["id"]}"
  puts "description: #{card["desc"].truncate(50)}"
  puts "list: #{card["listname"]}"
  puts "url: #{card["shortUrl"]}"
  puts "last activity: #{card["dateLastActivity"]}"
  puts "labels: #{labels(card)}"
  puts "actions:"
  card_actions(card["actions"])
  puts
  puts
end

def add_member(action)
  name = action['data']['member']['name']
  puts "    member added: #{name}"
end

def comment(action)
  puts "    comment: #{action["data"]["text"]}"
end

def copy_card(action)
  old_name = action['data']['cardSource']['name']
  puts "    copied from: #{old_name}"
end

def copy_comment_card(action)
  old_name = action['data']['cardSource']['name']
  copied_comment =  action['data']['text']
  puts "    copied from: #{old_name}"
  puts "    copied comment: #{copied_comment}"
end

def update_card(action)
  changed = action["data"]["old"].keys[0]
  if changed == "idList"
    list_changed(changed, action)
    return
  elsif changed == "desc"
    desc_changed(changed, action)
    return
  end
  puts "    was: #{action["data"]["old"]}"
  puts "    is now: #{action["data"]["card"][changed]}"
end

def delete_card(action)
  puts " "
  puts "  #{action["type"]}"
  puts "    performed at: #{action["date"]}"
  puts "    performed by: #{action["memberCreator"]["fullName"]}"
  card_id = action["data"]["card"]["id"]
  card_name = 
  puts "    card: #{card_id}"
  puts "    from board: #{action["data"]["board"]["name"]}"
  puts "    from list: #{action["data"]["list"]["name"]}"
end

def move_card_board(action)
  puts "    from board: #{action["data"]["board"]["name"]}"
  puts "    to board: #{action["data"]["boardSource"]["id"]}"
end

def list_changed(changed, action)
  old_list_id = action["data"]["old"].values[0]
  old_list_name = @lists.select {|l| l["id"] == old_list_id}[0]["name"]

  new_list_id = action["data"]["card"][changed]
  new_list_name = @lists.select {|l| l["id"] == new_list_id}[0]["name"]
  
  puts "    moved from: #{old_list_name}"
  puts "    moved to: #{new_list_name}"
end

def desc_changed(changed, action)
  old_desc = action["data"]["old"][changed]
  new_desc = action["data"]["card"][changed]
  diffs = Diffy::Diff.new("#{old_desc}\n", "#{new_desc}\n").to_s(:color)
  if (!old_desc.nil? && !new_desc.nil?) && new_desc.size > 100 || old_desc.size > 100
    puts "    diff:"
    puts "#{diffs}"
    puts
    return
  end
  puts "    description was: #{old_desc}"
  puts "    changed to: #{new_desc}"
end

def attachment_added(action)
  puts "    file name: #{action["data"]["attachment"]["name"]}"
end

def checklist_added(action)
  puts "    checklist name: #{action["data"]["checklist"]["name"]}"
end

def checklist_item_changed(action)
  diffs = Diffy::Diff.new("#{action["old"]}\n", "#{action["new"]}\n").to_s(:color)
  puts "    diff:"
  puts "#{diffs}"
  puts
end

def update_check_item(action)
  puts "    checklist name: #{action["data"]["checklist"]["name"]}"
  puts "    check item: #{action["data"]["checkItem"]["name"]}"
  puts "    state: #{action["data"]["checkItem"]["state"]}"
end

def format_checklist_data(checklist)
  checklist.sort_by{|nn| nn["pos"] }.map {|n| "- [#{n["state"] == "complete" ? "x" : " " }] #{n["name"]}"}.join("\n")
end

def add_checklist_data(checklist_data, card)
  old_checklists = JSON.parse(File.read("checklists.json"))
  checklist_data.each do |cl_data|
    old_checklists.each do |old_cl_data|
      if old_cl_data["id"] == cl_data["idChecklist"]
        old_cl_data["checkItems"].each do |check_item|
          if check_item["id"] == cl_data["id"]
            unless check_item == cl_data
              formatted_old_cl_data = format_checklist_data(old_cl_data["checkItems"])
              formatted_cl_data = format_checklist_data(checklist_data)
              new_action = {
                "type"=>"changedChecklistItem",
                "date"=>"#{Time.now}",
                "old"=>"#{formatted_old_cl_data}",
                "new"=>"#{formatted_cl_data}"
              }
              card["actions"] << new_action
            end
          end
        end
      end
    end
  end
end

puts "---------------------------------------------------------"
new_checklists = {}
old_checklists = JSON.parse(File.read("checklists.json"))
cards.each do |card|
  if !(card["idChecklists"] || []).empty?
    card["idChecklists"].each do |checklist_id|
      new_checklist = JSON.parse(`curl "https://api.trello.com/1/checklists/#{checklist_id}/checkItems?key=#{@key}&token=#{@token}&checkItem_fields=all"`)
      new_checklists[checklist_id] = new_checklist
      old_checklist = old_checklists[checklist_id] || []
      if format_checklist_data(new_checklist) != format_checklist_data(old_checklist)
        new_action = {
          "type"=>"changedChecklistItem",
          "date"=>"#{Time.now}",
          "old"=>format_checklist_data(old_checklist),
          "new"=>format_checklist_data(new_checklist)
        }
        card["actions"] << new_action
      end
    end
  end
  describe_card(card)
end
File.open("checklists.json", 'w') {|f| f << new_checklists.to_json}
puts "no. of cards: #{cards.size}"

puts "---------------------------------------------------------"
puts "board actions:"
@board_actions.each do |action|
  describe_action(action)
end
