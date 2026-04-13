Jekyll::Hooks.register :site, :post_read do |site|
  # permalink 사용으로 인해 리디렉션이 필요한 포스트 목록 작성
  redirects = {}
  site.posts.docs.each do |post|
    if post.data.key?('permalink')
      slug = Jekyll::Utils.slugify(post.data['title'])
      default_url = "/posts/#{slug}/"
      
      # 설정된 permalink가 제목 기반의 기본 주소와 다른 경우에만 후보로 등록
      if post.data['permalink'] != default_url
        redirects[default_url] = post
      end
    end
  end

  # 사이트의 모든 문서(포스트, 페이지 등) 본문을 통합하여 검색 대상으로 설정
  all_searchable_content = (site.posts.docs + site.pages).map(&:content).join(" ")

  # 본문에서 실제로 사용된 이전 주소에 대해서만 리디렉션을 활성화
  redirects.each do |url, post|
    # 해당 주소가 본문에 링크 등으로 포함되어 있는지 확인
    if all_searchable_content.include?(url)
      post.data['redirect_from'] ||= []
      
      unless post.data['redirect_from'].include?(url)
        post.data['redirect_from'] << url
        puts "[AutoRedirect] Usage detected! Registered: #{url} -> #{post.data['permalink']}"
      end
    end
  end
end
