class MainController < ApplicationController
  before_filter :set_username, :except => [:google_callback, :login, :callback, :webfinger, :users, :statuses, :feeds]
  protect_from_forgery :only => [:create, :update, :destroy]

    require "time"
    require "socket"
    require "openid"
    require 'openid/store/filesystem'
  
  def set_username
    unless cookies[:username]
      redirect_to "/main/login"
    end
    @user = User.find_by_username(cookies[:username])
    @user ||= User.create(:username => cookies[:username], :host => "localhost")
  end

  def login
    redirect_to "https://www.google.com/accounts/o8/ud?openid.ns=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0&openid.claimed_id=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0%2Fidentifier_select&openid.identity=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0%2Fidentifier_select&openid.return_to=http%3A%2F%2Fredrob.in%2Fmain%2Fgoogle_callback&openid.realm=http%3A%2F%2Fredrob.in&openid.assoc_handle=AOQobUe3thI9enZCfFqMh-tGmc_G3g64oUPX7vPBgIqsIoz7_LkmpM4Xp-dMxFYl41fsw_aX&openid.mode=checkid_setup&openid.ns.ext1=http%3A%2F%2Fopenid.net%2Fsrv%2Fax%2F1.0&openid.ext1.mode=fetch_request&openid.ext1.type.firstname=http%3A%2F%2Faxschema.org%2FnamePerson%2Ffirst&openid.ext1.type.lastname=http%3A%2F%2Faxschema.org%2FnamePerson%2Flast&openid.ext1.if_available=firstname%2Clastname&openid.ext1.type.email=http%3A%2F%2Fschema.openid.net%2Fcontact%2Femail&openid.ext1.required=email"

  end


  def google_callback
    @openid = params[:"openid.claimed_id"]
    cookies[:username] = params[:"openid.ext1.value.email"].split("@").first
    redirect_to "/"
  end
    
  def main
    @show_replies = params[:replies]
    @subs = []
    @user.subscriptions = [] if @user.subscriptions.nil?
    @user.subscriptions.each_with_index do |sub,index|
      @subs << "<br/>" if index != 0 && index % 10 == 0 
      @subs << "<a title='#{sub[:user]}@#{sub[:host]}' href='#{sub[:profile]}' border=0 target='_blank'><img src='#{sub[:image]}' width=48 height=48 border=0></a>"

    end
     @statuses = []
     @user.subscriptions.each do |sub|
       user = User.find(:first, :conditions => "username = '#{sub[:user]}' AND host = '#{sub[:host]}'")
       user.statuses.each do |status|
         @statuses << { :text => status[:text],
                        :updated => status[:updated_at],
                        :user => sub[:user],
                        :image => sub[:image],
                        :host => sub[:host],
                        :conversation => status[:conversation],
                        :id => status[:id],
                        :url => status[:url],
                        :author => status[:author],
                        :salmon => status[:salmon],
                        :profile => sub[:profile]}
        end
      end
      @user.statuses.each do |status|
        @statuses << { :text => status[:title],
                       :updated => status[:updated_at],
                       :user => @user.username,
                       :host => "redrob.in",
                       :image => "http://www.owlnet.rice.edu/~psyc101/pomerantz/NAmerican%20Robin.jpg",
                       :conversation => status[:conversation],
                       :url => status[:url],
                       :salmon => status[:salmon],
                       :profile => @user.profile
                       }
      end

  end
  
  def findname
    user = params[:user]
    users = []
    found_users = User.find_all_by_username(user)
    if found_users.empty?
      render :text => "none".to_json unless performed?
    end
    found_users.each do |user|
      users << "#{user.username}@#{user.host}"
    end
    render :text => users.to_json  unless performed?
  end  
  
  def subscribe
    finger = Redfinger.finger(params[:remotename])
    profile = finger.profile_page.first.to_s
    user,host = params[:remotename].split("@")
    User.create(:username => user, :host => host, :profile => profile) unless User.find(:first, :conditions => "username='#{user}' AND host='#{host}'")
    feed_url = finger.updates_from.first.to_s
    if feed_url.nil?
      render and return :text => "error".to_json
    end
    Rails.logger.info "in sub method"
    xml = HTTParty.get(feed_url)
    hub = FeedTool.is_push?(xml)
    Rails.logger.info "#{feed_url} #{hub}"
    doc = Nokogiri::XML(xml)
    doc.remove_namespaces!
    #this_url = doc.xpath("//link[@rel='self']").first['href']
    image = doc.xpath("//link[@rel='avatar']").first['href'] unless doc.xpath("//link[@rel='avatar']").first.nil?
    image ||= "http://www.appscout.com/images/Google%20Buzz%20logo.JPG" 
    Rails.logger.info "HITTING HUB #{hub} with topic #{feed_url} SUBSCRIBING"
    res = HTTParty.post(hub, :body => { :"hub.callback" => :"http://redrob.in/main/callback/#{user}/#{host}",
                                  :"hub.mode" => "subscribe",
                                  :"hub.topic" => feed_url,
                                  :"hub.verify" => "sync" })
    Rails.logger.info "GOT RESPONSE FROM HUB, LOOK FOR CALLBACK"
    @user.subscriptions = [] if @user.subscriptions.nil?
    match = nil
    user,host = params[:remotename].split("@")
    @user.subscriptions.each do |sub|
      match = 1 if sub[:user] == user && sub[:host] == host
    end
        
    @user.subscriptions << { :hub => hub, 
                             :topic => feed_url, 
                             :user => user,
                             :host => host, 
                             :image => image,
                             :profile => finger.profile_page.first.to_s } if match.nil?
    @user.save
    render :text => "#{hub} #{feed_url} #{image}".to_json
  end  
    
  def callback
    challenge = params[:"hub.challenge"]
    unless challenge.nil?
      render :text => challenge
      return
    end
    user = params[:user]
    host = params[:host]
    if params[:salmon] == "lookup"
      finger = Redfinger.finger("#{user}@#{host}")
      salmon = finger.salmon.first.to_s
    end

    xml = request.body.read
    #Rails.logger.info "XML: #{xml}"
    doc = Nokogiri::XML(xml)
    doc.remove_namespaces!
    #Rails.logger.info xml
    unless xml.empty?
      text = doc.xpath("//content").last.text
      hub = doc.xpath("//link[@rel='hub']").first['href']
      salmon = doc.xpath("//link[@rel='http://salmon-protocol.org/ns/salmon-replies']").first['href']  unless doc.xpath("//link[@rel='http://salmon-protocol.org/ns/salmon-replies']").first.nil?
      topic = doc.xpath("//link[@rel='self']").first['href'] unless doc.xpath("//link[@rel='self']").first.nil? 
      updated = doc.xpath("//updated").last.text 
      author = doc.xpath("//author/uri").first.text
      url = doc.xpath("//entry/link[@rel='alternate']").first['href']
      conversation = doc.xpath("//link[@rel='ostatus:conversation']").last['href'] unless doc.xpath("//link[@rel='ostatus:conversation']").last.nil?
      found_user = User.find(:first, :conditions => "username  = '#{user}' AND host = '#{host}'")
      #render and return :text => "user not found" if found_user.nil?
      unless found_user.nil?
        s = TCPSocket.open("realtime.redrob.in","8081")
        User.find_all_by_host("localhost").each do |ping|
          Rails.logger.info "PIGNING #{ping.username}"
          s.puts "ADDMESSAGE #{ping.username} ping"
        end
        s.close
        found_user.statuses.create(:text => text, :conversation => conversation, :url => url, :author => author, :salmon => salmon)
        found_user.salmon = salmon
        found_user.save
      end
    end
    render :text => ""
  end
  
  def feeds
    user = User.find(:first, :conditions =>  "username = '#{params[:username]}' AND host = 'localhost'" )
    if user.nil?
      render :text => "User does not exist!", :status => 400 and return
    end
    header = <<TEMPLATE
<?xml version="1.0" encoding="UTF-8"?>
<feed xml:lang="en-US" xmlns="http://www.w3.org/2005/Atom" xmlns:thr="http://purl.org/syndication/thread/1.0" xmlns:georss="http://www.georss.org/georss" xmlns:activity="http://activitystrea.ms/spec/1.0/" xmlns:media="http://purl.org/syndication/atommedia" xmlns:poco="http://portablecontacts.net/spec/1.0" xmlns:ostatus="http://ostatus.org/schema/1.0">
 <generator uri="http://redrob.in" version="0.1alpha">Robin</generator>
 <id>http://redrob.in/feeds/#{user.username}</id>
 <title>#{user.username} timeline</title>
 <subtitle>Updates from #{user.username} on Robin!</subtitle>
 <logo>http://avatar.identi.ca/3919-96-20080826101830.png</logo>
 <updated>#{Time.now.xmlschema}</updated>
<author>
 <name>#{user.username}</name>
 <uri>http://redrob.in/users/#{user.username}</uri>

</author>
 <link href="http://pubsubhubbub.appspot.com/" rel="hub"/>
 <link href="http://redrob.in/salmon/#{user.username}" rel="http://salmon-protocol.org/ns/salmon-replies"/>
 <link href="http://redrob.in/salmon/#{user.username}" rel="http://salmon-protocol.org/ns/salmon-mention"/>
 <link href="http://redrob.in/feeds/#{user.username}" rel="self" type="application/atom+xml"/>
<activity:subject>
 <activity:object-type>http://activitystrea.ms/schema/1.0/person</activity:object-type>
 <id>http://redrob.in/users/#{user.username}</id>
 <title>Tyler Gillies</title>
 <link ref="alternate" type="text/html" href="http://redrob.in/users/#{user.username}" />
 <link rel="avatar" type="image/jpeg" media:width="178" media:height="178" href="http://www.owlnet.rice.edu/~psyc101/pomerantz/NAmerican%20Robin.jpg"/>
 <link rel="avatar" type="image/png" media:width="96" media:height="96" href="http://www.owlnet.rice.edu/~psyc101/pomerantz/NAmerican%20Robin.jpg"/>
 <link rel="avatar" type="image/png" media:width="48" media:height="48" href="http://www.owlnet.rice.edu/~psyc101/pomerantz/NAmerican%20Robin.jpg"/>
 <link rel="avatar" type="image/png" media:width="24" media:height="24" href="http://www.owlnet.rice.edu/~psyc101/pomerantz/NAmerican%20Robin.jpg"/>
<poco:preferredUsername>#{user.username}</poco:preferredUsername>
<poco:displayName>Tyler Gillies</poco:displayName>
<poco:note>rails hacker</poco:note>
<poco:address>
 <poco:formatted>America</poco:formatted>
</poco:address>
<poco:urls>
 <poco:type>http://identi.ca/tjgillies</poco:type>
 <poco:value>http://redrob.in/users/#{user.username}</poco:value>
 <poco:primary>true</poco:primary>

</poco:urls>
</activity:subject>
TEMPLATE

    entries = []
    
    user.statuses.each do |status|
    replystring = "<link rel='ostatus:attention' href='#{status.reply_author}' /><link rel='related' href='#{status.reply}' /><thr:in-reply-to ref='#{status.reply}' href='#{status.reply}'></thr:in-reply-to>" if status.reply
       
      entry = <<TEMPLATE
<entry>
 <title>#{status.text}</title>
 <link rel="alternate" type="text/html" href="http://redrob.in/statuses/#{status.id}"/>
 <id>http://redrob.in/statuses/#{status.id}</id>
 <published>#{status.created_at.xmlschema}</published>
 <updated>#{status.updated_at.xmlschema}</updated>
 <link rel="related" href="http://identi.ca/notice/28141232"/>

 #{replystring}
 <link rel="ostatus:conversation" href="#{status.conversation}"/>
 <ostatus:forward ref="#{status.conversation}" href="#{status.conversation}"></ostatus:forward>
 <content type="html">#{status.text}</content>

</entry>
TEMPLATE
      entries << entry
    end
    feed = header + entries.reverse.join("\n") + "</feed>"
    render :text => feed, :content_type => "application/atom+xml"
  end
  
  def post
    reply = params[:reply]
    Rails.logger.info "REPLY: #{reply}"
    salmon = params[:salmon]
    Rails.logger.info "SALMON NIL? #{salmon.nil?}, SALMON: #{salmon}"
    if salmon.nil?  || salmon.empty?
      finger = Redfinger.finger(params[:user]) unless params[:user].nil?
      Rails.logger.info params[:user]
      salmon = finger.salmon.first.to_s unless finger.nil?
      Rails.logger.info "SALMON: #{salmon}"
    end
    
    reply_author = params[:reply_author]
    conversation = params[:conversation]
    author = params[:user]
    user,host = params[:user].split("@") unless params[:user].nil? 
    person = User.find(:first, :conditions => "username = '#{user}' AND host = '#{host}'")
    username = @user.username
    text = params[:text]
    title = params[:title]
    text[/@\w+/] = "&lt;a href='#{person.profile}'&gt;@#{user}&lt;/a&gt;" unless params[:user].nil?
    conversation ||= "http://redrob.in/conversations/#{Conversation.create.id}"
    Rails.logger.info "THIS IS TEXT: #{title}"
    status = @user.statuses.create(:title => title, :text => text, :conversation => conversation, :reply => reply, :reply_author => reply_author)
    hub = "http://pubsubhubbub.appspot.com/"
    HTTParty.post(hub, :body => { :"hub.mode" => :publish, :"hub.url" => "http://redrob.in/feeds/#{@user.username}" })
    HTTParty.post("http://redrob.in/salmon/send_salmon", :body => { :title => title, :text => text, :status_id => status.id, :username => username, :salmon => salmon, :author => author }) unless reply.nil?

    render :text => "Ok".to_json
  end    
  
  def webfinger
    uri = params[:uri]
    username = uri.gsub(/(?:acct:)?([^@]+)@redrob\.in/){ $1 }

    output = <<-EOF
<?xml version='1.0' encoding='UTF-8'?>
<XRD xmlns='http://docs.oasis-open.org/ns/xri/xrd-1.0'>
 
    <Subject>acct:#{username}@redrob.in</Subject>
    <Alias>http://redrob.in/users/#{username}</Alias>
 
    <Link rel='magic-public-key'
          href='data:application/magic-public-key;RSA.xA_Fc4BlK439U1Ow5vUyY5A-Zcdpaniyt7v45jnd5S6-dIUWdHtGSN5sYF6hNb8OyMyVJVqAkBtzG0jGNL4HJQ==.AQAB' />
    <Link rel='http://webfinger.net/rel/profile-page'
          type='text/html'
          href='http://redrob.in/users/#{username}' />
    <Link rel='http://salmon-protocol.org/ns/salmon-mention'
          href='http://redrob.in/salmon/user/#{username}' />
    <Link rel='http://schemas.google.com/g/2010#updates-from'
          type='application/atom+xml'
          href='http://redrob.in/feeds/#{username}' />
</XRD>
    EOF
    render :text => output, :content_type => "application/xrd+xml"
  end
  
  def users
    @username = params[:username]
    @this_user = User.find(:first, :conditions => "username = '#{@username}' AND host = 'localhost'")
    if @this_user.nil?
      render :text => "no such user", :status => 400 and return
    end
        

  end
  
  def statuses
    status_number = params[:status_number]
    message = Status.find(status_number)
    render :text => message.title
  end

  def replies
    
  end
    
    
    
end
