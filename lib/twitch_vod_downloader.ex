defmodule TwitchVodDownloader do
  def get_token(client_id, video_id) do
    headers = [Accept: "application/vnd.twitchtv.v5+json", "Client-ID": client_id]

    url = "https://api.twitch.tv/api/vods/#{video_id}/access_token?as3=t"

    # fetch token

    IO.puts("Fetching access_token")

    body =
      case HTTPoison.get(url, headers, []) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          body

        {:ok, %HTTPoison.Response{status_code: 400}} ->
          raise "Bad request, is the client_id correct?"

        {:ok, %HTTPoison.Response{status_code: 404}} ->
          raise "Not Found"

        {:error, %HTTPoison.Error{reason: reason}} ->
          IO.inspect(reason)
          raise "Error occurred."
      end

    json = Jason.decode!(body)
    sig = json["sig"]
    token = json["token"]

    IO.puts("Got access token: #{token}")
    IO.puts("Signature: #{sig}")

    {token, sig}
  end

  def get_playlist_url({token, sig}, video_id) do
    url =
      "http://usher.twitch.tv/vod/#{video_id}?nauth=#{token}&nauthsig=#{sig}&allow_source=true&player=twitchweb&allow_spectre=true"

    meta_playlists =
      case HTTPoison.get(url) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          body

        {:ok, %HTTPoison.Response{status_code: 403, body: _body}} ->
          raise "Forbidden"

        {:error, %HTTPoison.Error{reason: reason}} ->
          IO.inspect(reason)
          raise "Error occurred."
      end

    Regex.run(~r<.*/chunked/index-dvr\.m3u8$>m, meta_playlists)
    |> List.first()
  end

  def get_parts(url) do
    base_url = Regex.replace(~r/index-dvr\.m3u8/, url, "")
    IO.puts("Base url: #{base_url}")
    playlist = HTTPoison.get!(url).body

    part_names =
      Regex.scan(~r<[0-9]+.ts>, playlist, capture: :all)
      |> Enum.map(fn p -> p |> List.first() end)

    {base_url, part_names}
  end

  def download_parts(base_url, parts, dest) do
    File.mkdir_p!(dest)

    Task.async_stream(
      parts,
      fn p ->
        IO.puts("Starting download for #{p}")
        %HTTPoison.Response{body: body} = HTTPoison.get!(base_url <> p)
        File.write(dest <> p, body)
      end,
      timeout: :infinity,
      max_concurrency: 20
    )
    |> Enum.map(fn {:ok, val} -> val end)

    :ok
  end

  def download_video_parts(video_id, dest) do
    client_id = "jzkbprff40iqj646a697cyrvl0zt2m6"

    token = get_token(client_id, video_id)

    {base_url, parts} =
      get_playlist_url(token, video_id)
      |> get_parts

    download_parts(base_url, parts, dest)
  end

  def merge_ts_files(dest) do
    # sort files in proper order.
    files =
      File.ls!(dest)
      |> Enum.sort(
        &(Integer.parse(Path.basename(&1, ".ts")) < Integer.parse(Path.basename(&2, ".ts")))
      )

    # check if the file alreadye exists
    if(File.exists?(dest <> "all.ts")) do
      IO.puts("Combined file already exists. Skipping.")
    else
      # merge all files.
      Enum.each(files, fn f ->
        File.write!(dest <> "all.ts", File.read!(dest <> f), [:append])
      end)
    end

    dest <> "all.ts"
  end

  def download_vod(video_id) do
    # Making required directories
    File.mkdir("./tmp")
    File.mkdir("./dest")

    # Define paths
    tmpDir = "./tmp/#{video_id}/"
    dest_file = "./dest/#{video_id}.ts"

    # Start download
    IO.puts("Starting download process")
    download_video_parts(video_id, tmpDir)

    # Start merging
    IO.puts("Starting merge process")
    merged_file = merge_ts_files(tmpDir)

    # Copy merged file to destiniation
    File.copy!(merged_file, dest_file)

    # Delete temp files
    IO.puts("Deleting temp files")
    File.rm_rf!(tmpDir)

    IO.puts("Done!")
  end

  def main(args) when args != [] do
    HTTPoison.start()

    video_id = args |> List.first()

    startTime = :os.system_time(:microsecond)

    download_vod(video_id)

    endTime = :os.system_time(:microsecond)
    duration = endTime - startTime
    IO.puts("Took #{duration}μs.")
  end

  def main(_args) do
    IO.puts("Pls gib video id")
  end
end
