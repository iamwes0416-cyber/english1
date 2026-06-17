export default async function handler(request, response) {
  const word = String(request.query.word || "").trim();

  if (!/^[A-Za-z][A-Za-z'-]{0,30}$/.test(word)) {
    response.status(400).send("Invalid word");
    return;
  }

  if (!process.env.OPENAI_API_KEY) {
    response.status(503).send("OPENAI_API_KEY is not configured");
    return;
  }

  const ttsResponse = await fetch("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: process.env.OPENAI_TTS_MODEL || "gpt-4o-mini-tts",
      voice: process.env.OPENAI_TTS_VOICE || "alloy",
      input: word,
      response_format: "mp3",
      instructions:
        process.env.OPENAI_TTS_INSTRUCTIONS ||
        "Pronounce this as a clear American English phonics word for a second-grade child. Say only the word, with no extra explanation.",
    }),
  });

  if (!ttsResponse.ok) {
    const errorText = await ttsResponse.text();
    response.status(ttsResponse.status).send(errorText);
    return;
  }

  const audioBuffer = Buffer.from(await ttsResponse.arrayBuffer());
  response.setHeader("Content-Type", "audio/mpeg");
  response.setHeader("Cache-Control", "s-maxage=86400, stale-while-revalidate=604800");
  response.status(200).send(audioBuffer);
}
