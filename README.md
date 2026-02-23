# PhysioAi 🩺💻

**PhysioAi** is a universal physiotherapy assistant designed to democratize access to rehabilitation through AI-powered motion analysis. Our vision is to create a comprehensive, multi-modal application that assists patients in recovering from a wide range of physical conditions right from their homes.

## 🚀 Current Status

We have successfully implemented the first two modules of the platform, leveraging advanced on-device computer vision and signal processing:

### 🔹 Face Therapy (Bell's Palsy Recovery)
- Uses **MediaPipe Face Mesh** to track facial landmarks in real-time.
- Analysis for facial symmetry exercises (Smile, Eyebrow lift, Eye closure).
- **Status**: Functional baseline, requires refinement in clinical logic and AI accuracy.

### 🔹 Voice Therapy
- Real-time **pitch detection** (Hz) and **volume analysis**.
- Integrated **Speech-to-Text (STT)** to verify articulation and pronunciation.
- **Status**: Functional baseline, needs improved noise cancellation and advanced acoustic markers.

## 🗺 Roadmap & Vision

We are working towards making PhysioAi a one-stop-shop for all physiotherapy needs. Our upcoming focus areas include:

- [ ] **Hand & Wrist Mobility**: Utilizing Mediapipe Hand Landmarker for range-of-motion assessment.
- [ ] **Leg & Gait Analysis**: Pose estimation for walking patterns and lower limb rehabilitation.
- [ ] **Postural Correction**: Real-time feedback on body alignment and ergonomic safety.
- [ ] **AI Model Refinement**: Moving towards fine-tuned clinical models for higher precision metrics.
- [ ] **App-Level Polish**: Improving the UX/UI to be more accessible for patients with motor or visual impairments.

## 🤝 Contributing & Collaboration

We are in the early stages of this journey and **need your help** to scale this impact! 

Whether you are an AI researcher, a Flutter developer, or a Physiotherapist, your contributions are invaluable.

### How to Contribute:
1. **Explore**: Check the issues or current implementation.
2. **Propose**: Suggest new features or clinical protocols.
3. **Build**: Fork the repo and submit a PR (`git checkout -b feature/NewModule`).

### Focus Areas for Feedback:
- Improving AI detection accuracy under varied lighting/noise.
- Designing clinical validation protocols for stored metrics.
- Developing modular architecture for easy addition of new exercises.

## 🛠 Tech Stack
- **Framework**: [Flutter](https://flutter.dev)
- **AI/ML**: Google ML Kit (Face Detection, Face Mesh), Custom Signal Processing.
- **Data**: Privacy-first local storage.

## 📄 License
This project is licensed under the MIT License.

## 📞 Contact
Join us in building the future of digital rehabilitation. Created with ❤️ for better recovery.


