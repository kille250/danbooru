require 'test_helper'

class BulkUpdateRequestTest < ActiveSupport::TestCase
  context "a bulk update request" do
    setup do
      @admin = FactoryBot.create(:admin_user)
      CurrentUser.user = @admin
      CurrentUser.ip_addr = "127.0.0.1"
    end

    teardown do
      CurrentUser.user = nil
      CurrentUser.ip_addr = nil
    end

    should "parse the tags inside the script" do
      @bur = create(:bulk_update_request, script: %{
        create alias aaa -> 000
        create implication bbb -> 111
        remove alias ccc -> 222
        remove implication ddd -> 333
        mass update eee id:1 -fff ~ggg hhh* -> 444 -555
        category iii -> meta
      })

      assert_equal(%w[000 111 222 333 444 aaa bbb ccc ddd eee iii], @bur.tags)
    end

    should_eventually "parse tags with tag type prefixes inside the script" do
      @bur = create(:bulk_update_request, script: "mass update aaa -> artist:bbb")
      assert_equal(%w[aaa bbb], @bur.tags)
    end

    context "on approval" do
      setup do
        @post = create(:post, tag_string: "foo aaa")
        @script = '
          create alias foo -> bar
          create implication bar -> baz
          mass update aaa -> bbb
        '

        @bur = create(:bulk_update_request, script: @script, user: @admin)
        @bur.approve!(@admin)

        assert_enqueued_jobs(3)
        perform_enqueued_jobs

        @ta = TagAlias.where(:antecedent_name => "foo", :consequent_name => "bar").first
        @ti = TagImplication.where(:antecedent_name => "bar", :consequent_name => "baz").first
      end

      should "reference the approver in the automated message" do
        assert_match(Regexp.compile(@admin.name), @bur.forum_post.body)
      end

      should "set the BUR approver" do
        assert_equal(@admin.id, @bur.approver.id)
      end

      should "create aliases/implications" do
        assert_equal("active", @ta.status)
        assert_equal("active", @ti.status)
      end

      should "process mass updates" do
        assert_equal("bar baz bbb", @post.reload.tag_string)
      end

      should "set the alias/implication approvers" do
        assert_equal(@admin.id, @ta.approver.id)
        assert_equal(@admin.id, @ti.approver.id)
      end
    end

    should "create a forum topic" do
      bur = create(:bulk_update_request, reason: "zzz", script: "create alias aaa -> bbb")

      assert_equal(true, bur.forum_post.present?)
      assert_match(/\[bur:#{bur.id}\]/, bur.forum_post.body)
      assert_match(/zzz/, bur.forum_post.body)
    end

    context "that has an invalid alias" do
      setup do
        @alias1 = create(:tag_alias, antecedent_name: "aaa", consequent_name: "bbb", creator: @admin)
        @req = FactoryBot.build(:bulk_update_request, :script => "create alias bbb -> aaa")
      end

      should "not validate" do
        assert_difference("TagAlias.count", 0) do
          @req.save
        end
        assert_equal(["Error: A tag alias for aaa already exists (create alias bbb -> aaa)"], @req.errors.full_messages)
      end
    end

    context "for an implication that is redundant with an existing implication" do
      should "not validate" do
        FactoryBot.create(:tag_implication, :antecedent_name => "a", :consequent_name => "b")
        FactoryBot.create(:tag_implication, :antecedent_name => "b", :consequent_name => "c")
        bur = FactoryBot.build(:bulk_update_request, :script => "imply a -> c")
        bur.save

        assert_equal(["Error: a already implies c through another implication (create implication a -> c)"], bur.errors.full_messages)
      end
    end

    context "for an implication that is redundant with another implication in the same BUR" do
      setup do
        FactoryBot.create(:tag_implication, :antecedent_name => "b", :consequent_name => "c")
        @bur = FactoryBot.build(:bulk_update_request, :script => "imply a -> b\nimply a -> c")
        @bur.save
      end

      should "not process" do
        assert_no_difference("TagImplication.count") do
          @bur.approve!(@admin)
        end
      end

      should_eventually "not validate" do
        assert_equal(["Error: a already implies c through another implication (create implication a -> c)"], @bur.errors.full_messages)
      end
    end

    context "for a `category <tag> -> type` change" do
      should "work" do
        tag = Tag.find_or_create_by_name("tagme")
        bur = FactoryBot.create(:bulk_update_request, :script => "category tagme -> meta")
        bur.approve!(@admin)

        assert_equal(Tag.categories.meta, tag.reload.category)
      end

      should "work for a new tag" do
        bur = FactoryBot.create(:bulk_update_request, :script => "category new_tag -> meta")
        bur.approve!(@admin)

        assert_not_nil(Tag.find_by_name("new_tag"))
        assert_equal(Tag.categories.meta, Tag.find_by_name("new_tag").category)
      end
    end

    context "with an associated forum topic" do
      setup do
        @topic = create(:forum_topic, title: "[bulk] hoge", creator: @admin)
        @post = create(:forum_post, topic: @topic, creator: @admin)
        @req = FactoryBot.create(:bulk_update_request, :script => "create alias AAA -> BBB", :forum_topic_id => @topic.id, :forum_post_id => @post.id, :title => "[bulk] hoge")
      end

      should "gracefully handle validation errors during approval" do
        @req.stubs(:update!).raises(BulkUpdateRequestProcessor::Error.new("blah"))
        assert_difference("ForumPost.count", 1) do
          @req.approve!(@admin)
        end

        assert_equal("pending", @req.reload.status)
      end

      should "leave the BUR pending if there is an unexpected error during approval" do
        @req.forum_updater.stubs(:update).raises(RuntimeError.new("blah"))
        assert_raises(RuntimeError) { @req.approve!(@admin) }

        # XXX Raises "Couldn't find BulkUpdateRequest without an ID". Possible
        # rails bug? (cf rails #34637, #34504, #30167, #15018).
        # @req.reload

        @req = BulkUpdateRequest.find(@req.id)
        assert_equal("pending", @req.status)
      end

      should "downcase the text" do
        assert_equal("create alias aaa -> bbb", @req.script)
      end

      should "update the topic when processed" do
        assert_difference("ForumPost.count") do
          @req.approve!(@admin)
        end

        assert_match(/approved/, @post.reload.body)
      end

      should "update the topic when rejected" do
        @req.approver_id = @admin.id

        assert_difference("ForumPost.count") do
          @req.reject!(@admin)
        end

        assert_match(/rejected/, @post.reload.body)
      end

      should "reference the rejector in the automated message" do
        @req.reject!(@admin)
        assert_match(Regexp.compile(@admin.name), @req.forum_post.body)
      end

      should "not send @mention dmails to the approver" do
        assert_no_difference("Dmail.count") do
          @req.approve!(@admin)
        end
      end
    end

    context "when searching" do
      setup do
        @bur1 = FactoryBot.create(:bulk_update_request, title: "foo", script: "create alias aaa -> bbb", user_id: @admin.id)
        @bur2 = FactoryBot.create(:bulk_update_request, title: "bar", script: "create implication bbb -> ccc", user_id: @admin.id)
        @bur1.approve!(@admin)
      end

      should "work" do
        assert_equal([@bur2.id, @bur1.id], BulkUpdateRequest.search.map(&:id))
        assert_equal([@bur1.id], BulkUpdateRequest.search(user_name: @admin.name, approver_name: @admin.name, status: "approved").map(&:id))
      end
    end
  end
end
