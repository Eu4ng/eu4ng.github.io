import os
import re
from pathlib import Path

POSTS_DIR = Path("_posts")

def main():
    if not POSTS_DIR.exists():
        print(f"Error: '{POSTS_DIR}' directory not found. Please run this script in the Jekyll root directory.")
        return

    # 정규표현식 설정
    permalink_search = re.compile(r'^permalink:\s*/posts/(\d+)/?\s*$', re.MULTILINE)
    permalink_remove = re.compile(r'^permalink:.*?\r?\n', re.MULTILINE)
    date_pattern = re.compile(r'^date:\s*(.+)$', re.MULTILINE)

    max_index = 0
    files_to_process = []
    
    # 1. 1차 순회: 모든 파일의 기존 permalink 확인 및 max_index 추출
    md_files = []
    for root, _, files in os.walk(POSTS_DIR):
        for file in files:
            if file.endswith(".md"):
                md_files.append(Path(root) / file)

    for file_path in md_files:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()

        if not content.startswith("---"):
            continue
            
        end_idx = content.find("---", 3)
        if end_idx == -1:
            continue
            
        front_matter = content[:end_idx+3]
        match = permalink_search.search(front_matter)
        
        if match:
            idx = int(match.group(1))
            if idx > max_index:
                max_index = idx
                
        # 날짜 정보 추출 (정렬용)
        date_match = date_pattern.search(front_matter)
        if date_match:
            sort_key = date_match.group(1).strip().strip("'\"")
        else:
            filename = file_path.name
            if len(filename) >= 10 and filename[:10].replace("-", "").isdigit():
                sort_key = filename[:10]
            else:
                sort_key = "0000-00-00"
                
        # 기존 index가 있으면 해당 index 유지, 없으면 None
        existing_idx = int(match.group(1)) if match else None
        
        files_to_process.append({
            'path': file_path,
            'content': content,
            'end_idx': end_idx,
            'sort_key': sort_key,
            'existing_idx': existing_idx,
            'front_matter': front_matter
        })

    # 2. None인 (새로운) 파일들은 날짜순으로 정렬
    files_to_assign = [f for f in files_to_process if f['existing_idx'] is None]
    files_to_assign.sort(key=lambda x: x['sort_key'])

    # 3. 새로운 파일들에 인덱스 할당
    current_index = max_index + 1
    for f in files_to_assign:
        f['existing_idx'] = current_index
        current_index += 1

    changed_files = 0
    
    # 4. 모든 파일에 대해 permalink 위치를 date 아래로 교정 및 적용
    for f in files_to_process:
        content = f['content']
        end_idx = content.find("---", 3)
        front_matter = content[:end_idx+3]
        
        target_idx = f['existing_idx']
        new_permalink_line = f"permalink: /posts/{target_idx}/"
        
        # 기존 permalink 라인 완전히 삭제
        cleaned_front_matter = permalink_remove.sub("", front_matter)
        
        # date 라인 찾기
        date_match = date_pattern.search(cleaned_front_matter)
        
        if date_match:
            # date 라인의 끝나는 위치
            insert_pos = date_match.end()
            
            # 다음 문자가 줄바꿈이면 건너뛰어 다음 줄 첫 번째 위치로 이동
            if cleaned_front_matter[insert_pos:insert_pos+2] == '\r\n':
                insert_pos += 2
            elif cleaned_front_matter[insert_pos:insert_pos+1] == '\n':
                insert_pos += 1
                
            final_front_matter = cleaned_front_matter[:insert_pos] + new_permalink_line + "\n" + cleaned_front_matter[insert_pos:]
        else:
            # 혹시 date가 없는 파일이면 기존처럼 마지막 --- 직전에 삽입
            insert_pos = cleaned_front_matter.find("---", 3)
            final_front_matter = cleaned_front_matter[:insert_pos] + new_permalink_line + "\n" + cleaned_front_matter[insert_pos:]

        if front_matter != final_front_matter:
            new_content = final_front_matter + content[end_idx+3:]
            with open(f['path'], "w", encoding="utf-8") as file:
                file.write(new_content)
            print(f"[설정 변경] {f['path'].name} -> {new_permalink_line} (date 아래 위치)")
            changed_files += 1

    print(f"\n처리가 완료되었습니다! 변경/추가된 파일 개수: {changed_files}개")

if __name__ == "__main__":
    main()
