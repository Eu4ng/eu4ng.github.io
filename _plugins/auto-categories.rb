#!/usr/bin/env ruby
#
# Automatically assign categories based on the subfolder structure under _posts.
# e.g. _posts/Unreal Engine/2024-01-01-title.md => categories: ["Unreal Engine"]
#      _posts/Unreal Engine/GAS/2024-01-01-title.md => categories: ["Unreal Engine", "GAS"]

Jekyll::Hooks.register :posts, :post_init do |post|
  # Only auto-assign if categories are not explicitly set in front matter
  if post.data['categories'].nil? || post.data['categories'].empty?
    # post.relative_path is like "_posts/Unreal Engine/GAS/2024-01-01-title.md"
    rel = post.relative_path.sub(%r{^_posts/}, '')
    dirs = File.dirname(rel).split('/')
    dirs.reject! { |d| d == '.' }

    post.data['categories'] = dirs unless dirs.empty?
  end
end
