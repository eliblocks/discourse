# frozen_string_literal: true

require_relative 'base'
require 'tiny_tds'

# Import script for Telligent communities
#
# It's really hard to find all attachments, but the script tries to do it anyway.
#
# You can supply a JSON file if you need to map and ignore categories during the import
# by providing the path to the file in the `CATEGORY_MAPPING` environment variable.
# You can also add tags to remapped categories and remap multiple old forums into one
# category. Here's an example of such a `mapping.json` file:
#
# {
#   "ignored_forum_ids": [41, 360, 378],
#
#   "mapping": [
#     {
#       "category": ["New Category 1"],
#       "forums": [
#         { "id": 348, "tag": "some_tag" },
#         { "id": 347, "tag": "another_tag" }
#       ]
#     },
#     {
#       "category": ["New Category 2"],
#       "forums": [
#         { "id": 9 }
#       ]
#     },
#     {
#       "category": ["Nested", "Category"],
#       "forums": [
#         { "id": 322 }
#       ]
#     }
#   ]
# }

class ImportScripts::Telligent < ImportScripts::Base
  BATCH_SIZE ||= 1000
  LOCAL_AVATAR_REGEX ||= /\A~\/.*(?<directory>communityserver-components-(?:selectable)?avatars)\/(?<path>[^\/]+)\/(?<filename>.+)/i
  REMOTE_AVATAR_REGEX ||= /\Ahttps?:\/\//i
  EMBEDDED_ATTACHMENT_REGEX ||= /<a href="\/cfs-file(?:\.ashx)?\/__key\/(?<directory>[^\/]+)\/(?<path>[^\/]+)\/(?<filename1>.+?)".*?>(?<filename2>.*?)<\/a>/i

  CATEGORY_LINK_NORMALIZATION = '/.*?(f\/\d+)$/\1'
  TOPIC_LINK_NORMALIZATION = '/.*?(f\/\d+\/t\/\d+)$/\1'

  def initialize
    super()

    @client = TinyTds::Client.new(
      host: ENV["DB_HOST"],
      username: ENV["DB_USERNAME"],
      password: ENV["DB_PASSWORD"],
      database: ENV["DB_NAME"],
      timeout: 60 # the user query is very slow
    )

    SiteSetting.tagging_enabled = true
  end

  def execute
    add_permalink_normalizations
    import_categories
    import_users
    import_topics
    import_posts
    mark_topics_as_solved
  end

  def import_users
    puts "", "Importing users..."

    user_conditions = <<~SQL
      (
        EXISTS(SELECT 1
               FROM te_Forum_Threads t
               WHERE t.UserId = u.UserID) OR
        EXISTS(SELECT 1
               FROM te_Forum_ThreadReplies r
               WHERE r.UserId = u.UserID)
      )
    SQL

    last_user_id = -1
    total_count = count(<<~SQL)
      SELECT COUNT(1) AS count
      FROM cs_Users u
      WHERE #{user_conditions}
    SQL
    import_count = 0

    loop do
      rows = query(<<~SQL)
        SELECT *
        FROM (
            SELECT TOP #{BATCH_SIZE}
              u.UserID, u.Email, u.UserName,u.CreateDate, p.PropertyName, p.PropertyValue
            FROM cs_Users u
              LEFT OUTER JOIN (
                SELECT NULL AS UserID, ap.UserId AS MembershipID, x.PropertyName, x.PropertyValue
                FROM aspnet_Profile ap
                  CROSS APPLY dbo.GetProperties(ap.PropertyNames, ap.PropertyValuesString) x
                WHERE ap.PropertyNames NOT LIKE '%:-1%' AND
                      x.PropertyName IN ('bio', 'commonName', 'location', 'webAddress')
                UNION
                SELECT up.UserID, NULL AS MembershipID, x.PropertyName, CAST(x.PropertyValue AS NVARCHAR) AS PropertyValue
                  FROM cs_UserProfile up
                    CROSS APPLY dbo.GetProperties(up.PropertyNames, up.PropertyValues) x
                  WHERE up.PropertyNames NOT LIKE '%:-1%' AND
                        x.PropertyName IN ('avatarUrl', 'BannedUntil', 'UserBanReason')
              ) p ON p.UserID = u.UserID OR p.MembershipID = u.MembershipID
            WHERE u.UserID > #{last_user_id} AND #{user_conditions}
            ORDER BY u.UserID
        ) x
          PIVOT (
            MAX(PropertyValue)
            FOR PropertyName
            IN (bio, commonName, location, webAddress, avatarUrl, BannedUntil, UserBanReason)
          ) Y
        ORDER BY UserID
      SQL

      break if rows.blank?
      last_user_id = rows[-1]["UserID"]

      if all_records_exist?(:users, rows.map { |row| row["UserID"] })
        import_count += rows.size
        next
      end

      create_users(rows, total: total_count, offset: import_count) do |row|
        {
          id: row["UserID"],
          email: row["Email"],
          username: row["UserName"],
          name: row["commonName"],
          created_at: row["CreateDate"],
          bio_raw: html_to_markdown(row["bio"]),
          location: row["location"],
          website: row["webAddress"],
          post_create_action: proc do |user|
            import_avatar(user, row["avatarUrl"])
            suspend_user(user, row["BannedUntil"], row["UserBanReason"])
          end
        }
      end

      import_count += rows.size
    end
  end

  # TODO move into base importer (create_user) and use consistent error handling
  def import_avatar(user, avatar_url)
    return if ENV["FILE_BASE_DIR"].blank? || avatar_url.blank? || avatar_url.include?("anonymous")

    if match_data = avatar_url.match(LOCAL_AVATAR_REGEX)
      avatar_path = File.join(ENV["FILE_BASE_DIR"],
                              match_data[:directory].gsub("-", "."),
                              match_data[:path].split("-"),
                              match_data[:filename])

      if File.file?(avatar_path)
        @uploader.create_avatar(user, avatar_path)
      else
        STDERR.puts "Could not find avatar: #{avatar_path}"
      end
    elsif avatar_url.match?(REMOTE_AVATAR_REGEX)
      UserAvatar.import_url_for_user(avatar_url, user) rescue nil
    end
  end

  def suspend_user(user, banned_until, ban_reason)
    return if banned_until.blank?

    if banned_until = DateTime.parse(banned_until) > DateTime.now
      user.suspended_till = banned_until
      user.suspended_at = DateTime.now
      user.save!

      StaffActionLogger.new(Discourse.system_user).log_user_suspend(user, ban_reason)
    end
  end

  def import_categories
    if ENV['CATEGORY_MAPPING']
      import_mapped_forums_as_categories
    else
      import_groups_and_forums_as_categories
    end
  end

  def import_mapped_forums_as_categories
    puts "", "Importing categories..."

    json = JSON.parse(File.read(ENV['CATEGORY_MAPPING']))

    categories = []
    @forum_ids_to_tags = {}
    @ignored_forum_ids = json["ignored_forum_ids"]

    json["mapping"].each do |m|
      parent_id = nil
      last_index = m["category"].size - 1
      forum_ids = []

      m["forums"].each do |f|
        forum_ids << f["id"]
        @forum_ids_to_tags[f["id"]] = f["tag"] if f["tag"].present?
      end

      m["category"].each_with_index do |name, index|
        id = Digest::MD5.hexdigest(name)
        categories << {
          id: id,
          name: name,
          parent_id: parent_id,
          forum_ids: index == last_index ? forum_ids : nil
        }
        parent_id = id
      end
    end

    create_categories(categories) do |c|
      if category_id = category_id_from_imported_category_id(c[:id])
        map_forum_ids(category_id, c[:forum_ids])
        nil
      else
        {
          id: c[:id],
          name: c[:name],
          parent_category_id: category_id_from_imported_category_id(c[:parent_id]),
          post_create_action: proc do |category|
            map_forum_ids(category.id, c[:forum_ids])
          end
        }
      end
    end
  end

  def map_forum_ids(category_id, forum_ids)
    return if forum_ids.blank?

    forum_ids.each do |id|
      url = "f/#{id}"
      Permalink.create(url: url, category_id: category_id) unless Permalink.exists?(url: url)
      add_category(id, Category.find_by_id(category_id))
    end
  end

  def import_groups_and_forums_as_categories
    puts "", "Importing parent categories..."
    parent_categories = query(<<~SQL)
      SELECT GroupID, Name, HtmlDescription, DateCreated, SortOrder
      FROM cs_Groups g
      WHERE (SELECT COUNT(1)
             FROM te_Forum_Forums f
             WHERE f.GroupId = g.GroupID) > 1
      ORDER BY SortOrder, Name
    SQL

    create_categories(parent_categories) do |row|
      {
        id: "G#{row['GroupID']}",
        name: clean_category_name(row["Name"]),
        description: html_to_markdown(row["HtmlDescription"]),
        position: row["SortOrder"]
      }
    end

    puts "", "Importing child categories..."
    child_categories = query(<<~SQL)
      SELECT ForumId, GroupId, Name, Description, DateCreated, SortOrder
      FROM te_Forum_Forums
      ORDER BY GroupId, SortOrder, Name
    SQL

    create_categories(child_categories) do |row|
      parent_category_id = parent_category_id_for(row)

      if category_id = replace_with_category_id(child_categories, parent_category_id)
        add_category(row['ForumId'], Category.find_by_id(category_id))
        url = "f/#{row['ForumId']}"
        Permalink.create(url: url, category_id: category_id) unless Permalink.exists?(url: url)
        nil
      else
        {
          id: row['ForumId'],
          parent_category_id: parent_category_id,
          name: clean_category_name(row["Name"]),
          description: html_to_markdown(row["Description"]),
          position: row["SortOrder"],
          post_create_action: proc do |category|
            url = "f/#{row['ForumId']}"
            Permalink.create(url: url, category_id: category.id) unless Permalink.exists?(url: url)
          end
        }
      end
    end
  end

  def parent_category_id_for(row)
    category_id_from_imported_category_id("G#{row['GroupId']}") if row.key?("GroupId")
  end

  def replace_with_category_id(child_categories, parent_category_id)
    parent_category_id if only_child?(child_categories, parent_category_id)
  end

  def only_child?(child_categories, parent_category_id)
    count = 0

    child_categories.each do |row|
      count += 1 if parent_category_id_for(row) == parent_category_id
    end

    count == 1
  end

  def clean_category_name(name)
    CGI.unescapeHTML(name)
      .strip
  end

  def import_topics
    puts "", "Importing topics..."

    last_topic_id = -1
    total_count = count("SELECT COUNT(1) AS count FROM te_Forum_Threads t WHERE #{ignored_forum_sql_condition}")

    batches do |offset|
      rows = query(<<~SQL)
        SELECT TOP #{BATCH_SIZE}
          t.ThreadId, t.ForumId, t.UserId, t.TotalViews,
          t.Subject, t.Body, t.DateCreated, t.IsLocked, t.StickyDate,
          a.ApplicationTypeId, a.ApplicationId, a.ApplicationContentTypeId, a.ContentId, a.FileName, a.IsRemote
        FROM te_Forum_Threads t
          LEFT JOIN te_Attachments a
            ON (a.ApplicationId = t.ForumId AND a.ApplicationTypeId = 0 AND a.ContentId = t.ThreadId AND
                a.ApplicationContentTypeId = 0)
        WHERE t.ThreadId > #{last_topic_id} AND #{ignored_forum_sql_condition}
        ORDER BY t.ThreadId
      SQL

      break if rows.blank?
      last_topic_id = rows[-1]["ThreadId"]
      next if all_records_exist?(:post, rows.map { |row| import_topic_id(row["ThreadId"]) })

      create_posts(rows, total: total_count, offset: offset) do |row|
        user_id = user_id_from_imported_user_id(row["UserId"]) || Discourse::SYSTEM_USER_ID

        post = {
          id: import_topic_id(row["ThreadId"]),
          title: CGI.unescapeHTML(row["Subject"]),
          raw: raw_with_attachment(row, user_id, :topic),
          category: category_id_from_imported_category_id(row["ForumId"]),
          user_id: user_id,
          created_at: row["DateCreated"],
          closed: row["IsLocked"],
          views: row["TotalViews"],
          post_create_action: proc do |action_post|
            topic = action_post.topic
            Jobs.enqueue_at(topic.pinned_until, :unpin_topic, topic_id: topic.id) if topic.pinned_until
            url = "f/#{row['ForumId']}/t/#{row['ThreadId']}"
            Permalink.create(url: url, topic_id: topic.id) unless Permalink.exists?(url: url)
          end
        }

        if row["StickyDate"] > Time.now
          post[:pinned_until] = row["StickyDate"]
          post[:pinned_at] = row["DateCreated"]
        end

        post
      end
    end
  end

  def import_topic_id(topic_id)
    "T#{topic_id}"
  end

  def ignored_forum_sql_condition
    @ignored_forum_sql_condition ||= @ignored_forum_ids.present? \
      ? "t.ForumId NOT IN (#{@ignored_forum_ids.join(',')})" \
      : "1 = 1"
  end

  def import_posts
    puts "", "Importing posts..."

    last_post_id = -1
    total_count = count(<<~SQL)
      SELECT COUNT(1) AS count
      FROM te_Forum_ThreadReplies tr
        JOIN te_Forum_Threads t ON (tr.ThreadId = t.ThreadId)
      WHERE #{ignored_forum_sql_condition}
    SQL

    batches do |offset|
      rows = query(<<~SQL)
        SELECT TOP #{BATCH_SIZE}
          tr.ThreadReplyId, tr.ThreadId, tr.UserId, pr.ThreadReplyId AS ParentReplyId,
          tr.Body, tr.ThreadReplyDate,
          CONVERT(BIT,
                  CASE WHEN tr.AnswerVerifiedUtcDate IS NOT NULL AND NOT EXISTS(
                      SELECT 1
                      FROM te_Forum_ThreadReplies x
                      WHERE
                        x.ThreadId = tr.ThreadId AND x.ThreadReplyId < tr.ThreadReplyId AND x.AnswerVerifiedUtcDate IS NOT NULL
                  )
                    THEN 1
                  ELSE 0 END) AS IsFirstVerifiedAnswer,
          a.ApplicationTypeId, a.ApplicationId, a.ApplicationContentTypeId, a.ContentId, a.FileName, a.IsRemote
        FROM te_Forum_ThreadReplies tr
          JOIN te_Forum_Threads t ON (tr.ThreadId = t.ThreadId)
          LEFT JOIN te_Forum_ThreadReplies pr ON (tr.ParentReplyId = pr.ThreadReplyId AND tr.ParentReplyId < tr.ThreadReplyId AND tr.ThreadId = pr.ThreadId)
          LEFT JOIN te_Attachments a
            ON (a.ApplicationId = t.ForumId AND a.ApplicationTypeId = 0 AND a.ContentId = tr.ThreadReplyId AND
                a.ApplicationContentTypeId = 1)
        WHERE tr.ThreadReplyId > #{last_post_id} AND #{ignored_forum_sql_condition}
        ORDER BY tr.ThreadReplyId
      SQL

      break if rows.blank?
      last_post_id = rows[-1]["ThreadReplyId"]
      next if all_records_exist?(:post, rows.map { |row| row["ThreadReplyId"] })

      create_posts(rows, total: total_count, offset: offset) do |row|
        imported_parent_id = row["ParentReplyId"]&.nonzero? ? row["ParentReplyId"] : import_topic_id(row["ThreadId"])
        parent_post = topic_lookup_from_imported_post_id(imported_parent_id)
        user_id = user_id_from_imported_user_id(row["UserId"]) || Discourse::SYSTEM_USER_ID

        if parent_post
          post = {
            id: row["ThreadReplyId"],
            raw: raw_with_attachment(row, user_id, :post),
            user_id: user_id,
            topic_id: parent_post[:topic_id],
            created_at: row["ThreadReplyDate"],
            reply_to_post_number: parent_post[:post_number]
          }

          post[:custom_fields] = { is_accepted_answer: "true" } if row["IsFirstVerifiedAnswer"]
          post
        else
          puts "Failed to import post #{row['ThreadReplyId']}. Parent was not found."
        end
      end
    end
  end

  def raw_with_attachment(row, user_id, type)
    raw, embedded_paths, upload_ids = replace_embedded_attachments(row["Body"], user_id)
    raw = html_to_markdown(raw) || ""

    filename = row["FileName"]
    return raw if ENV["FILE_BASE_DIR"].blank? || filename.blank?

    if row["IsRemote"]
      return "#{raw}\n#{filename}"
    end

    path = File.join(
      ENV["FILE_BASE_DIR"],
      "telligent.evolution.components.attachments",
      "%02d" % row["ApplicationTypeId"],
      "%02d" % row["ApplicationId"],
      "%02d" % row["ApplicationContentTypeId"],
      ("%010d" % row["ContentId"]).scan(/.{2}/),
      clean_filename(filename)
    )

    unless embedded_paths.include?(path)
      if File.file?(path)
        upload = @uploader.create_upload(user_id, path, filename)

        if upload.present? && upload.persisted? && !upload_ids.include?(upload.id)
          raw = "#{raw}\n#{@uploader.html_for_upload(upload, filename)}"
        end
      else
        id = type == :topic ? row['ThreadId'] : row['ThreadReplyId']
        STDERR.puts "Could not find file for #{type} #{id}: #{path}"
      end
    end

    raw
  end

  def replace_embedded_attachments(raw, user_id)
    paths = []
    upload_ids = []

    return [raw, paths, upload_ids] if ENV["FILE_BASE_DIR"].blank?

    raw = raw.gsub(EMBEDDED_ATTACHMENT_REGEX) do
      filename, path = attachment_path(Regexp.last_match)

      if File.file?(path)
        upload = @uploader.create_upload(user_id, path, filename)

        if upload.present? && upload.persisted?
          paths << path
          upload_ids << upload.id
          @uploader.html_for_upload(upload, filename)
        end
      else
        STDERR.puts "Could not find file: #{path}"
      end
    end

    [raw, paths, upload_ids]
  end

  def clean_filename(filename)
    filename = CGI.unescapeHTML(filename)
    filename.gsub!(/[\x00\/\\:\*\?\"<>\|]/, '_')

    %w|( ) # % - _ [ ] = , ' ~ ! + { } & @ #|.each do |c|
      number = "#{c.ord.to_s(16).upcase}00"
      filename.gsub!("_#{number}_", c)
      filename.gsub!("_#{number}#{number}_", c * 2)
    end

    filename
  end

  def attachment_path(match_data)
    filename, path = join_attachment_path(match_data, filename_index: 2)
    filename, path = join_attachment_path(match_data, filename_index: 1) unless File.file?(path)
    [filename, path]
  end

  # filenames are a total mess - try to guess the correct filename
  # works for 70% of all files
  def join_attachment_path(match_data, filename_index:)
    filename = clean_filename(match_data[:"filename#{filename_index}"])
    base_path = File.join(
      ENV["FILE_BASE_DIR"],
      match_data[:directory].gsub("-", ".").downcase,
      match_data[:path].gsub("+", " ").gsub(/_\h{4}_/, "?").split(/[\.\-]/).map(&:strip)
    )

    original_filename = filename.dup

    filename.gsub!(/[_\- ]/, "?")
    path = File.join(base_path, filename)
    paths = Dir.glob(path, File::FNM_CASEFOLD)
    if (path = paths.first) && paths.size == 1
      filename = File.basename(path)
      return [filename, path]
    end

    filename = original_filename.dup
    filename.gsub!(/_\h{2}00_/, "?")
    filename.gsub!(/_\h{2}00\h{2}00_/, "??")
    filename.gsub!(/_\h{2}00\h{2}00\h{2}00_/, "???")
    filename.gsub!(/[_\- ]/, "?")
    path = File.join(base_path, filename)
    paths = Dir.glob(path, File::FNM_CASEFOLD)
    if (path = paths.first) && paths.size == 1
      filename = File.basename(path)
      return [filename, path]
    end

    filename = original_filename.dup
    filename.gsub!(/_\h{4}_/, "?")
    filename.gsub!(/_\h{4}\h{4}_/, "??")
    filename.gsub!(/_\h{4}\h{4}\h{4}_/, "???")
    filename.gsub!(/[_\- ]/, "?")
    path = File.join(base_path, filename)
    paths = Dir.glob(path, File::FNM_CASEFOLD)
    if (path = paths.first) && paths.size == 1
      filename = File.basename(path)
      return [filename, path]
    end

    [original_filename, File.join(base_path, original_filename)]
  end

  def html_to_markdown(html)
    return html if html.blank?

    md = HtmlToMarkdown.new(html).to_markdown
    md.gsub!(/\[quote.*?\]/, "\n" + '\0' + "\n")
    md.gsub!(/(?<!^)\[\/quote\]/, "\n[/quote]\n")
    md.strip!
    md
  end

  def mark_topics_as_solved
    puts "", "Marking topics as solved..."

    DB.exec <<~SQL
      INSERT INTO topic_custom_fields (name, value, topic_id, created_at, updated_at)
      SELECT 'accepted_answer_post_id', pcf.post_id, p.topic_id, p.created_at, p.created_at
        FROM post_custom_fields pcf
        JOIN posts p ON p.id = pcf.post_id
       WHERE pcf.name = 'is_accepted_answer' AND pcf.value = 'true'
    SQL
  end

  def add_permalink_normalizations
    normalizations = SiteSetting.permalink_normalizations
    normalizations = normalizations.blank? ? [] : normalizations.split('|')

    add_normalization(normalizations, CATEGORY_LINK_NORMALIZATION)
    add_normalization(normalizations, TOPIC_LINK_NORMALIZATION)

    SiteSetting.permalink_normalizations = normalizations.join('|')
  end

  def add_normalization(normalizations, normalization)
    normalizations << normalization unless normalizations.include?(normalization)
  end

  def batches
    super(BATCH_SIZE)
  end

  def query(sql)
    @client.execute(sql).to_a
  end

  def count(sql)
    query(sql).first["count"]
  end
end

ImportScripts::Telligent.new.perform
